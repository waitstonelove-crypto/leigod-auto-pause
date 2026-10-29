using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace LeigodAutoPause
{
    internal static class Program
    {
        internal static string DataDir;
        internal static string LogPath;
        internal static string LockPath;
        internal static Config Cfg;

        private static Mutex _mutex;

        [STAThread]
        private static void Main()
        {
            DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LeigodAutoPause");
            LogPath = Path.Combine(DataDir, "autopause.log");
            LockPath = Path.Combine(DataDir, "instance.lock");

            try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; }
            catch { }

            try
            {
                if (!Directory.Exists(DataDir)) Directory.CreateDirectory(DataDir);
            }
            catch (Exception ex)
            {
                Log("cannot create data directory: " + ex.Message);
                return;
            }

            bool created;
            _mutex = new Mutex(true, "Local\\LeigodAutoPause", out created);
            if (!created)
            {
                Log("another instance is already running; exiting");
                return;
            }

            try
            {
                Cfg = Config.Load(Path.Combine(DataDir, "config.json"));
            }
            catch (Exception ex)
            {
                Log("config error: " + ex.Message);
                return;
            }

            try { File.WriteAllText(LockPath, Process.GetCurrentProcess().Id.ToString(), Encoding.ASCII); }
            catch { }

            Log(string.Format("watcher started (poll={0}s, pause on process exit, shutdown guard on)", Cfg.PollSeconds));

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var form = new WatcherForm(Cfg))
            {
                Application.Run(form);
            }

            try { _mutex.ReleaseMutex(); }
            catch { }
        }

        internal static void Log(string message)
        {
            try
            {
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > 1024 * 1024)
                {
                    try { if (File.Exists(LogPath + ".old")) File.Delete(LogPath + ".old"); }
                    catch { }
                    try { File.Move(LogPath, LogPath + ".old"); }
                    catch { }
                }
                File.AppendAllText(LogPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + "\r\n",
                    Encoding.UTF8);
            }
            catch { }
        }
    }

    internal sealed class Config
    {
        public string Phone;
        public string PasswordMd5;
        public int PollSeconds = 2;

        public static Config Load(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("config.json not found");

            string json = File.ReadAllText(path, Encoding.UTF8);
            var ser = new JavaScriptSerializer();
            var dict = ser.Deserialize<Dictionary<string, object>>(json);
            if (dict == null) throw new Exception("config.json is empty");

            var c = new Config();
            if (dict.ContainsKey("phone")) c.Phone = Convert.ToString(dict["phone"]);
            if (dict.ContainsKey("passwordMd5")) c.PasswordMd5 = Convert.ToString(dict["passwordMd5"]);
            if (dict.ContainsKey("pollSeconds") && dict["pollSeconds"] != null)
            {
                try { c.PollSeconds = Convert.ToInt32(dict["pollSeconds"]); }
                catch { c.PollSeconds = 2; }
            }

            if (string.IsNullOrEmpty(c.Phone) || string.IsNullOrEmpty(c.PasswordMd5))
                throw new Exception("config is missing phone/passwordMd5");
            if (c.PollSeconds < 1) c.PollSeconds = 1;

            return c;
        }
    }

    internal sealed class WatcherForm : Form
    {
        private readonly Config _cfg;
        private readonly System.Windows.Forms.Timer _timer;
        private bool _hasSeen;
        private int _trackedPid;
        private bool _pausedForThisRun;
        private bool _hiddenLogged;

        public WatcherForm(Config cfg)
        {
            _cfg = cfg;

            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-3000, -3000);
            Size = new Size(1, 1);

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = cfg.PollSeconds * 1000;
            _timer.Tick += OnTick;
            _timer.Start();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0011) // WM_QUERYENDSESSION
            {
                Api.Pause(_cfg, "query-end-session", 3000);
                m.Result = (IntPtr)1; // allow shutdown
                return;
            }
            base.WndProc(ref m);
        }

        private void OnTick(object sender, EventArgs e)
        {
            try
            {
                Process ui = FindUiProcess();
                if (ui != null)
                {
                    if (!_hasSeen) Program.Log(string.Format("client UI process detected (PID={0})", ui.Id));
                    _hasSeen = true;
                    _trackedPid = ui.Id;
                    _pausedForThisRun = false;
                    _hiddenLogged = false;
                    ui.Dispose();
                    return;
                }

                if (!_hasSeen || _trackedPid == 0) return;

                if (!IsAlive(_trackedPid))
                {
                    if (_pausedForThisRun) return;
                    _pausedForThisRun = true;
                    Program.Log("client process exited; pausing now");
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        if (Api.Pause(_cfg, "process-exit", 20000)) Program.Log("time paused automatically");
                    });
                }
                else if (!_hiddenLogged)
                {
                    Program.Log("client window hidden; process still running (no pause)");
                    _hiddenLogged = true;
                }
            }
            catch (Exception ex)
            {
                Program.Log("watcher error: " + ex.Message);
            }
        }

        private static Process FindUiProcess()
        {
            Process[] all = Process.GetProcessesByName("leigod");
            Process found = null;
            foreach (Process p in all)
            {
                try
                {
                    if (found == null && p.MainWindowHandle != IntPtr.Zero) found = p;
                    else p.Dispose();
                }
                catch
                {
                    try { p.Dispose(); }
                    catch { }
                }
            }
            return found;
        }

        private static bool IsAlive(int pid)
        {
            try
            {
                using (Process p = Process.GetProcessById(pid)) { return true; }
            }
            catch { return false; }
        }
    }

    internal static class Api
    {
        private static readonly object TokenLock = new object();
        private static string _token;

        public static bool Pause(Config cfg, string reason, int timeoutMs)
        {
            int attempts = (reason == "process-exit" || reason == "manual-test") ? 3 : 1;

            for (int attempt = 1; attempt <= attempts; attempt++)
            {
                try
                {
                    using (var http = new HttpClient())
                    {
                        http.Timeout = TimeSpan.FromMilliseconds(timeoutMs);

                        string token = GetToken(http, cfg);
                        if (token == null)
                        {
                            if (attempt < attempts) { Thread.Sleep(1500 * attempt); continue; }
                            return false;
                        }

                        Dictionary<string, object> resp = PostPause(http, token);
                        if (resp == null)
                        {
                            if (attempt < attempts) { Thread.Sleep(1500 * attempt); continue; }
                            return false;
                        }

                        int code = GetInt(resp, "code");
                        string msg = GetStr(resp, "msg");

                        if (code == 400007)
                        {
                            Program.Log("token expired, re-login");
                            lock (TokenLock) { _token = null; }
                            token = GetToken(http, cfg);
                            if (token != null)
                            {
                                resp = PostPause(http, token);
                                if (resp != null)
                                {
                                    code = GetInt(resp, "code");
                                    msg = GetStr(resp, "msg");
                                }
                            }
                        }

                        if (code == 0 || code == 400803)
                        {
                            Program.Log(string.Format("pause OK: code={0} msg={1} ({2})", code, msg, reason));
                            return true;
                        }

                        Program.Log(string.Format("pause failed (attempt {0}/{1}): code={2} msg={3}", attempt, attempts, code, msg));
                    }
                }
                catch (Exception ex)
                {
                    Program.Log(string.Format("{0} -> pause error (attempt {1}/{2}): {3}", reason, attempt, attempts, ex.Message));
                }

                if (attempt < attempts) Thread.Sleep(1500 * attempt);
            }

            return false;
        }

        private static string GetToken(HttpClient http, Config cfg)
        {
            lock (TokenLock)
            {
                if (!string.IsNullOrEmpty(_token)) return _token;
                _token = Login(http, cfg);
                return _token;
            }
        }

        private static string Login(HttpClient http, Config cfg)
        {
            var body = new Dictionary<string, object>();
            body["username"] = cfg.Phone;
            body["password"] = cfg.PasswordMd5;
            body["user_type"] = "0";
            body["src_channel"] = "guanwang";
            body["code"] = "8fAAIgr3HHmcX7JY";
            body["country_code"] = 86;
            body["lang"] = "en";
            body["os_type"] = 5;

            var ser = new JavaScriptSerializer();
            string json = ser.Serialize(body);

            using (var content = new StringContent(json, Encoding.UTF8, "application/json"))
            {
                var resp = http.PostAsync("https://webapi.leigod.com/wap/login/bind", content).Result;
                string text = resp.Content.ReadAsStringAsync().Result;
                var dict = ParseJson(text, "login", resp);

                if (GetInt(dict, "code") == 0)
                {
                    var data = (dict.ContainsKey("data") ? dict["data"] : null) as Dictionary<string, object>;
                    var li = (data != null && data.ContainsKey("login_info") ? data["login_info"] : null) as Dictionary<string, object>;
                    if (li != null && li.ContainsKey("account_token"))
                    {
                        string token = Convert.ToString(li["account_token"]);
                        if (!string.IsNullOrEmpty(token))
                        {
                            Program.Log("login OK");
                            return token;
                        }
                    }
                }

                Program.Log("login failed: " + text);
                return null;
            }
        }

        private static Dictionary<string, object> PostPause(HttpClient http, string token)
        {
            var body = new Dictionary<string, object>();
            body["account_token"] = token;
            body["lang"] = "en";
            body["os_type"] = 5;

            var ser = new JavaScriptSerializer();
            string json = ser.Serialize(body);

            using (var content = new StringContent(json, Encoding.UTF8, "application/json"))
            {
                var resp = http.PostAsync("https://webapi.leigod.com/api/user/pause", content).Result;
                string text = resp.Content.ReadAsStringAsync().Result;
                return ParseJson(text, "pause", resp);
            }
        }

        private static Dictionary<string, object> ParseJson(string text, string what, HttpResponseMessage resp)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                Program.Log(string.Format("{0}: empty response (HTTP {1})", what, (int)resp.StatusCode));
                return null;
            }

            try
            {
                return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(text);
            }
            catch (Exception ex)
            {
                string preview = text.Length > 300 ? text.Substring(0, 300) : text;
                Program.Log(string.Format("{0}: non-JSON response (HTTP {1}): {2} | {3}", what, (int)resp.StatusCode, ex.Message, preview));
                return null;
            }
        }

        private static int GetInt(Dictionary<string, object> d, string key)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return -1;
            try { return Convert.ToInt32(d[key]); }
            catch { return -1; }
        }

        private static string GetStr(Dictionary<string, object> d, string key)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return "";
            return Convert.ToString(d[key]);
        }
    }
}
