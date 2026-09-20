//
// BreakReminder — Windows 版 (C# 5 / WinForms / .NET Framework 4.8, 系统自带运行时)
// 连续工作满 1 小时 → 弹窗提示 → 播放系统屏保 5 分钟 → 恢复正常
//
// 编译: 双击同目录 build.bat (调用 Windows 自带 csc, 无需安装任何环境)
// 托盘常驻 ☕ 图标; 设置存于 %APPDATA%\BreakReminder.ini; 日志在 %LOCALAPPDATA%\BreakReminder\log.txt
//

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BreakReminder
{
    static class Program
    {
        private static Mutex single;

        [STAThread]
        static void Main()
        {
            single = new Mutex(true, "BreakReminder_SingleInstance");
            if (!single.WaitOne(0, false))
            {
                MessageBox.Show("BreakReminder 已在运行（看右下角托盘 ☕ 图标）", "BreakReminder",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new AppContext());
        }
    }

    // ---------------- 配置 ----------------

    class Config
    {
        public double WorkSeconds = 3600;
        public double BreakSeconds = 300;
        public double IdleResetSeconds = 300;
        public double DialogTimeout = 30;
        public bool Sound = true;

        public static string IniPath()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                                "BreakReminder.ini");
        }

        public static Config Load()
        {
            Config c = new Config();
            try
            {
                if (!File.Exists(IniPath())) return c;
                string[] lines = File.ReadAllLines(IniPath());
                foreach (string raw in lines)
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = line.Substring(0, eq).Trim();
                    string v = line.Substring(eq + 1).Trim();
                    double d;
                    if (double.TryParse(v, out d))
                    {
                        if (k == "workMin") c.WorkSeconds = Math.Max(1, d) * 60;
                        else if (k == "breakMin") c.BreakSeconds = Math.Max(0.5, d) * 60;
                        else if (k == "idleResetMin") c.IdleResetSeconds = Math.Max(1, d) * 60;
                        else if (k == "dialogTimeoutSec") c.DialogTimeout = Math.Max(3, d);
                    }
                    int n;
                    if (k == "dismissSkip" && int.TryParse(v, out n)) { }   // 兼容旧配置, 已废弃
                    if (k == "soundOn") c.Sound = (v == "1" || v.ToLower() == "true");
                }
            }
            catch { }
            return c;
        }

        public void Save()
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# BreakReminder 配置 (分钟/秒)");
            sb.AppendLine("workMin=" + (WorkSeconds / 60).ToString("0.##"));
            sb.AppendLine("breakMin=" + (BreakSeconds / 60).ToString("0.##"));
            sb.AppendLine("idleResetMin=" + (IdleResetSeconds / 60).ToString("0.##"));
            sb.AppendLine("dialogTimeoutSec=" + DialogTimeout.ToString("0.##"));
            sb.AppendLine("soundOn=" + (Sound ? "1" : "0"));
            File.WriteAllText(IniPath(), sb.ToString());
        }
    }

    // ---------------- 系统空闲检测 ----------------

    static class Idle
    {
        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        public static double Seconds()
        {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(info);
            if (!GetLastInputInfo(ref info)) return 0;
            long idle = (long)Environment.TickCount - (long)info.dwTime;
            if (idle < 0) idle += (long)uint.MaxValue + 1;   // TickCount 回绕
            return idle / 1000.0;
        }
    }

    // ---------------- 系统屏保 ----------------

    static class Saver
    {
        public static string Find()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop"))
                {
                    if (k != null)
                    {
                        string v = k.GetValue("SCRNSAVE.EXE") as string;
                        if (!string.IsNullOrEmpty(v) && File.Exists(v)) return v;
                    }
                }
            }
            catch { }
            string blank = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "scrnsave.scr");
            if (File.Exists(blank)) return blank;
            return null;
        }
    }

    // ---------------- 日志 ----------------

    static class Log
    {
        private static readonly object gate = new object();
        public static void Write(string msg)
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                          "BreakReminder");
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                lock (gate)
                {
                    File.AppendAllText(Path.Combine(dir, "log.txt"),
                        string.Format("[{0:MM-dd HH:mm:ss}] {1}\r\n", DateTime.Now, msg));
                }
            }
            catch { }
        }
    }

    // ---------------- 通用圆角辅助 ----------------

    static class UIUtil
    {
        public static void Round(Control c, int r)
        {
            using (GraphicsPath p = new GraphicsPath())
            {
                int d = r * 2;
                p.AddArc(0, 0, d, d, 180, 90);
                p.AddArc(c.Width - d, 0, d, d, 270, 90);
                p.AddArc(c.Width - d, c.Height - d, d, d, 0, 90);
                p.AddArc(0, c.Height - d, d, d, 90, 90);
                p.CloseFigure();
                c.Region = new Region(p);
            }
        }

        public static Label Label(string text, Font font, Color color, int y, int width)
        {
            Label l = new Label();
            l.Text = text;
            l.Font = font;
            l.ForeColor = color;
            l.BackColor = Color.Transparent;
            l.TextAlign = ContentAlignment.MiddleCenter;
            l.AutoSize = false;
            l.SetBounds((400 - width) / 2, y, width, font.Height + 8);
            return l;
        }

        public static Button Button(string text, Color back, Color fore, int x, int y)
        {
            Button b = new Button();
            b.Text = text;
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = back;
            b.BackColor = back;
            b.ForeColor = fore;
            b.Font = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold);
            b.SetBounds(x, y, 130, 38);
            UIUtil.Round(b, 9);
            return b;
        }
    }

    // ---------------- 提示对话框 (居中大数字倒计时, 深色卡片) ----------------

    class BreakDialog : Form
    {
        private Label number;
        private System.Windows.Forms.Timer countdown;
        private int leftSec;

        public BreakDialog(double timeoutSec, double breakMin)
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            ShowInTaskbar = false;
            ClientSize = new Size(400, 232);
            BackColor = Color.FromArgb(28, 36, 51);
            UIUtil.Round(this, 20);

            Controls.Add(UIUtil.Label("☕ 连续工作一小时，请休息一下",
                new Font("Microsoft YaHei UI", 13f, FontStyle.Bold), Color.White, 28, 380));
            Controls.Add(UIUtil.Label("距自动进入屏保",
                new Font("Microsoft YaHei UI", 9.5f), Color.FromArgb(147, 161, 181), 62, 380));

            leftSec = Math.Max(1, (int)Math.Ceiling(timeoutSec));
            number = UIUtil.Label(leftSec.ToString(),
                new Font("Segoe UI", 46f, FontStyle.Bold), Color.FromArgb(111, 176, 255), 84, 380);
            Controls.Add(number);

            Controls.Add(UIUtil.Label(string.Format("本次休息 {0:0} 分钟", breakMin),
                new Font("Microsoft YaHei UI", 9.5f), Color.FromArgb(147, 161, 181), 156, 380));

            Button skip = UIUtil.Button("本次跳过", Color.FromArgb(42, 54, 72), Color.FromArgb(199, 210, 224), 56, 180);
            skip.DialogResult = DialogResult.Cancel;
            Controls.Add(skip);

            Button go = UIUtil.Button("进入休息", Color.FromArgb(58, 140, 247), Color.White, 214, 180);
            go.DialogResult = DialogResult.OK;
            Controls.Add(go);

            AcceptButton = go;
            CancelButton = skip;

            countdown = new System.Windows.Forms.Timer();
            countdown.Interval = 1000;
            countdown.Tick += OnSecond;
            countdown.Start();
        }

        private void OnSecond(object sender, EventArgs e)
        {
            leftSec--;
            if (leftSec <= 0)
            {
                countdown.Stop();
                DialogResult = DialogResult.OK;   // 倒计时结束 → 自动进入休息
                Close();
            }
            else
            {
                number.Text = leftSec.ToString();
            }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            countdown.Stop();
            base.OnFormClosed(e);
        }
    }

    // ---------------- 休息期间剩余时间浮层 (半透明, 点击穿透, 不遮挡屏保) ----------------

    class BreakOverlay : Form
    {
        private Label label;
        private System.Windows.Forms.Timer timer;
        private DateTime endTime;

        public BreakOverlay(double breakSeconds)
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(10, 13, 20);
            Opacity = 0.82;
            ClientSize = new Size(300, 48);

            label = new Label();
            label.Text = "休息中 · 还剩 0:00";
            label.Font = new Font("Microsoft YaHei UI", 12f, FontStyle.Bold);
            label.ForeColor = Color.White;
            label.BackColor = Color.Transparent;
            label.TextAlign = ContentAlignment.MiddleCenter;
            label.Dock = DockStyle.Fill;
            Controls.Add(label);
            UIUtil.Round(this, 24);

            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.X + (wa.Width - 300) / 2, wa.Bottom - 48 - 28);

            endTime = DateTime.Now.AddSeconds(breakSeconds);
            timer = new System.Windows.Forms.Timer();
            timer.Interval = 1000;
            timer.Tick += OnSecond;
            timer.Start();
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x20;          // WS_EX_TRANSPARENT: 鼠标点击穿透
                cp.ExStyle |= 0x8000000;     // WS_EX_NOACTIVATE: 不抢焦点
                return cp;
            }
        }

        private void OnSecond(object sender, EventArgs e)
        {
            TimeSpan left = endTime - DateTime.Now;
            if (left.TotalSeconds <= 0) { timer.Stop(); Close(); return; }
            label.Text = string.Format("休息中 · 还剩 {0}:{1:D2}", left.Minutes, left.Seconds);
        }
    }

    // ---------------- 设置窗口 ----------------

    class SettingsForm : Form
    {
        public delegate void SavedHandler();
        public event SavedHandler OnSaved;

        private NumericUpDown work, brk, idle, timeout;
        private CheckBox sound;
        private Config cfg;

        public SettingsForm(Config c)
        {
            cfg = c;
            Text = "BreakReminder 设置";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MaximizeBox = false;
            MinimizeBox = false;
            ClientSize = new Size(340, 212);

            work = AddRow("连续工作时长（分钟）", 24, (decimal)(cfg.WorkSeconds / 60), 1, 480, 0);
            brk = AddRow("休息(屏保)时长（分钟）", 60, (decimal)(cfg.BreakSeconds / 60), 0.5m, 60, 1);
            idle = AddRow("空闲多久算已休息（分钟）", 96, (decimal)(cfg.IdleResetSeconds / 60), 1, 120, 0);
            timeout = AddRow("提示框超时（秒）", 132, (decimal)cfg.DialogTimeout, 3, 300, 0);

            sound = new CheckBox();
            sound.Text = "触发时播放提示音";
            sound.Checked = cfg.Sound;
            sound.SetBounds(24, 166, 200, 24);
            Controls.Add(sound);

            Button save = new Button();
            save.Text = "保存";
            save.SetBounds(224, 162, 88, 32);
            save.Click += OnSave;
            Controls.Add(save);
        }

        private NumericUpDown AddRow(string label, int y, decimal value, decimal min, decimal max, int decimals)
        {
            Label l = new Label();
            l.Text = label;
            l.AutoSize = false;
            l.SetBounds(24, y + 2, 190, 22);
            Controls.Add(l);

            NumericUpDown n = new NumericUpDown();
            n.Minimum = min; n.Maximum = max;
            n.DecimalPlaces = decimals;
            n.Value = Math.Min(max, Math.Max(min, value));
            n.SetBounds(220, y, 90, 24);
            Controls.Add(n);
            return n;
        }

        private void OnSave(object sender, EventArgs e)
        {
            cfg.WorkSeconds = (double)work.Value * 60;
            cfg.BreakSeconds = (double)brk.Value * 60;
            cfg.IdleResetSeconds = (double)idle.Value * 60;
            cfg.DialogTimeout = (double)timeout.Value;
            cfg.Sound = sound.Checked;
            cfg.Save();
            if (OnSaved != null) OnSaved();
            Close();
        }
    }

    // ---------------- 应用主体 ----------------

    class AppContext : ApplicationContext
    {
        private Config cfg = Config.Load();
        private NotifyIcon tray;
        private ToolStripMenuItem statusItem, remainItem, pauseItem, autoItem;
        private readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer();
        private double accumulated = 0;
        private DateTime lastTick = DateTime.Now;
        private bool paused = false;
        private bool inBreak = false;
        private SettingsForm settingsForm;
        private BreakOverlay overlay;

        public AppContext()
        {
            BuildTray();
            tick.Interval = 1000;
            tick.Tick += OnTick;
            tick.Start();
            Log.Write(string.Format("BreakReminder 启动 | 工作 {0:0} 分钟 | 屏保 {1:0} 分钟 | 空闲清零 {2:0} 分钟",
                cfg.WorkSeconds / 60, cfg.BreakSeconds / 60, cfg.IdleResetSeconds / 60));
            UpdateMenu();
        }

        // ----- 托盘 -----

        private void BuildTray()
        {
            tray = new NotifyIcon();
            tray.Icon = MakeIcon();
            tray.Text = "BreakReminder 休息提醒";
            tray.Visible = true;

            ContextMenuStrip menu = new ContextMenuStrip();
            statusItem = new ToolStripMenuItem("已连续工作 0 / 60 分钟");
            statusItem.Enabled = false;
            remainItem = new ToolStripMenuItem("距下次休息还有 60 分钟");
            remainItem.Enabled = false;
            menu.Items.Add(statusItem);
            menu.Items.Add(remainItem);
            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem rest = new ToolStripMenuItem("立即休息(&R)", null, OnRestNow);
            ToolStripMenuItem reset = new ToolStripMenuItem("重新计时", null, OnReset);
            pauseItem = new ToolStripMenuItem("暂停监控", null, OnPause);
            menu.Items.Add(rest);
            menu.Items.Add(reset);
            menu.Items.Add(pauseItem);
            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem prefs = new ToolStripMenuItem("设置…", null, OnSettings);
            autoItem = new ToolStripMenuItem("开机自启", null, OnAutoStart);
            menu.Items.Add(prefs);
            menu.Items.Add(autoItem);
            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem quit = new ToolStripMenuItem("退出 BreakReminder", null, OnQuit);
            menu.Items.Add(quit);

            tray.ContextMenuStrip = menu;
            var dummy = menu.Handle;   // 提前创建句柄, 供后台线程 Invoke 使用
        }

        private Icon MakeIcon()
        {
            using (Bitmap bmp = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (GraphicsPath p = new GraphicsPath())
                    {
                        int r = 7;
                        p.AddArc(0, 0, r * 2, r * 2, 180, 90);
                        p.AddArc(32 - r * 2, 0, r * 2, r * 2, 270, 90);
                        p.AddArc(32 - r * 2, 32 - r * 2, r * 2, r * 2, 0, 90);
                        p.AddArc(0, 32 - r * 2, r * 2, r * 2, 90, 90);
                        p.CloseFigure();
                        using (LinearGradientBrush b = new LinearGradientBrush(
                            new Rectangle(0, 0, 32, 32),
                            Color.FromArgb(56, 140, 247), Color.FromArgb(18, 83, 204),
                            LinearGradientMode.Vertical))
                        {
                            g.FillPath(b, p);
                        }
                    }
                    using (Font f = new Font("Microsoft YaHei UI", 14f, FontStyle.Bold))
                    using (StringFormat sf = new StringFormat())
                    {
                        sf.Alignment = StringAlignment.Center;
                        sf.LineAlignment = StringAlignment.Center;
                        g.DrawString("休", f, Brushes.White, new RectangleF(0, -2, 32, 32), sf);
                    }
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        private void UpdateMenu()
        {
            int totalMin = (int)(cfg.WorkSeconds / 60);
            int m = (int)(accumulated / 60);
            if (inBreak)
            {
                statusItem.Text = "☕ 休息中…";
                remainItem.Text = "";
            }
            else if (paused)
            {
                statusItem.Text = "监控已暂停";
                remainItem.Text = "";
            }
            else
            {
                statusItem.Text = "已连续工作 " + m + " / " + totalMin + " 分钟";
                remainItem.Text = "距下次休息还有 " + Math.Max(0, totalMin - m) + " 分钟";
            }
            pauseItem.Text = paused ? "恢复监控" : "暂停监控";
            autoItem.Checked = AutoStartEnabled();
        }

        // ----- 计时主循环 -----

        private void OnTick(object sender, EventArgs e)
        {
            if (inBreak || paused) return;

            DateTime now = DateTime.Now;
            double dt = (now - lastTick).TotalSeconds;
            if (dt < 0 || dt > 5) dt = 1;      // 防跳变
            lastTick = now;
            double idle = Idle.Seconds();

            if (idle >= cfg.IdleResetSeconds)
            {
                if (accumulated > 60)
                    Log.Write(string.Format("键鼠空闲 {0:0} 分钟, 视为已休息过, 累计 {1:0} 分钟清零",
                        idle / 60, accumulated / 60));
                accumulated = 0;
            }
            else
            {
                accumulated += dt;
            }
            UpdateMenu();

            if (accumulated >= cfg.WorkSeconds)
                TriggerBreak();
        }

        // ----- 菜单动作 -----

        private void OnRestNow(object sender, EventArgs e)
        {
            if (inBreak) return;
            Log.Write("手动开始休息");
            inBreak = true;
            accumulated = 0;
            lastTick = DateTime.Now;
            UpdateMenu();
            PresentBreakDialog();
        }

        private void OnReset(object sender, EventArgs e)
        {
            accumulated = 0;
            lastTick = DateTime.Now;
            Log.Write("手动重新计时");
            UpdateMenu();
        }

        private void OnPause(object sender, EventArgs e)
        {
            paused = !paused;
            lastTick = DateTime.Now;
            Log.Write(paused ? "监控已暂停" : "监控已恢复");
            UpdateMenu();
        }

        private void OnSettings(object sender, EventArgs e)
        {
            if (settingsForm == null || settingsForm.IsDisposed)
            {
                settingsForm = new SettingsForm(cfg);
                settingsForm.OnSaved += delegate
                {
                    UpdateMenu();
                    Log.Write("设置已保存");
                };
            }
            settingsForm.Show();
            settingsForm.Activate();
        }

        private void OnQuit(object sender, EventArgs e)
        {
            tray.Visible = false;
            ExitThread();
        }

        // ----- 开机自启 (HKCU\...\Run) -----

        private bool AutoStartEnabled()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                {
                    return k != null && k.GetValue("BreakReminder") != null;
                }
            }
            catch { return false; }
        }

        private void OnAutoStart(object sender, EventArgs e)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                {
                    if (AutoStartEnabled()) k.DeleteValue("BreakReminder", false);
                    else k.SetValue("BreakReminder", "\"" + Application.ExecutablePath + "\"");
                }
                Log.Write(AutoStartEnabled() ? "已开启开机自启" : "已取消开机自启");
            }
            catch (Exception ex) { Log.Write("登录项切换失败: " + ex.Message); }
            UpdateMenu();
        }

        // ----- 休息流程 -----

        private void TriggerBreak()
        {
            inBreak = true;
            accumulated = 0;
            UpdateMenu();
            PresentBreakDialog();
        }

        /// 弹出居中倒计时确认卡 (自动触发与"立即休息"共用)
        private void PresentBreakDialog()
        {
            if (cfg.Sound) SystemSounds.Exclamation.Play();
            using (BreakDialog dlg = new BreakDialog(cfg.DialogTimeout, cfg.BreakSeconds / 60))
            {
                DialogResult r = dlg.ShowDialog();
                if (r == DialogResult.OK)
                {
                    Log.Write("开始休息 (倒计时结束/用户确认)");
                    StartBreakLoop();
                }
                else
                {
                    Log.Write("用户选择: 本次跳过");
                    inBreak = false;
                    lastTick = DateTime.Now;
                    UpdateMenu();
                }
            }
        }

        private void StartBreakLoop()
        {
            try { if (overlay != null) overlay.Close(); } catch { }
            overlay = new BreakOverlay(cfg.BreakSeconds);
            overlay.Show();
            Thread t = new Thread(BreakLoop);
            t.IsBackground = true;
            t.Start();
        }

        // 后台线程: Windows 上屏保是普通进程, 可直接启动/关闭
        private void BreakLoop()
        {
            string saver = Saver.Find();
            if (saver == null)
            {
                Log.Write("未找到系统屏保, 改为静置等待");
                DateTime s0 = DateTime.Now;
                while ((DateTime.Now - s0).TotalSeconds < cfg.BreakSeconds)
                {
                    Thread.Sleep(1000);
                    if ((DateTime.Now - s0).TotalSeconds >= 3 && Idle.Seconds() < 1) break;
                }
                BreakDone("休息结束, 已恢复正常");
                return;
            }

            Log.Write(string.Format("开始休息: 系统屏保 {0:0} 秒 (触碰键鼠立即结束)", cfg.BreakSeconds));
            DateTime start = DateTime.Now;

            while (true)
            {
                Process p;
                try { p = Process.Start(saver, "/s"); }
                catch (Exception ex) { Log.Write("屏保启动失败: " + ex.Message); Thread.Sleep(5000); continue; }
                if (p == null) { Thread.Sleep(2000); continue; }

                // 屏保窗口显示后把浮层重新压到最顶 (同属置顶窗口, 后出现者在上)
                Thread.Sleep(700);
                try
                {
                    BreakOverlay o = overlay;
                    if (o != null && !o.IsDisposed)
                        o.Invoke((MethodInvoker)delegate { o.TopMost = false; o.TopMost = true; });
                }
                catch { }

                // 等屏保退出(键鼠输入关掉了它), 或休息时间到
                while (!p.HasExited && (DateTime.Now - start).TotalSeconds < cfg.BreakSeconds)
                    Thread.Sleep(300);

                if (!p.HasExited)
                {
                    try { p.Kill(); } catch { }     // 时间到: 程序直接关屏保, 桌面立即恢复
                    BreakDone("休息结束, 已恢复正常");
                    return;
                }

                // 屏保被键鼠输入关掉: 宽限期(3秒, 防点"马上休息"后手部余动)过后立即结束休息
                if ((DateTime.Now - start).TotalSeconds >= 3)
                {
                    BreakDone("检测到键鼠活动, 提前结束休息");
                    return;
                }
                Thread.Sleep(300);
            }
        }

        private void BreakDone(string msg)
        {
            Log.Write(msg);
            try
            {
                BreakOverlay o = overlay;
                overlay = null;
                if (o != null && !o.IsDisposed)
                    o.Invoke((MethodInvoker)delegate { o.Close(); });
            }
            catch { }
            try
            {
                Control ui = (Control)tray.ContextMenuStrip;
                ui.Invoke((MethodInvoker)delegate
                {
                    inBreak = false;
                    accumulated = 0;
                    lastTick = DateTime.Now;
                    UpdateMenu();
                });
            }
            catch { }
        }
    }
}
