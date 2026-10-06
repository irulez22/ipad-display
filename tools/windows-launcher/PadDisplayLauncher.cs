using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

class PadDisplayLauncher : Form
{
    ComboBox display = new ComboBox();
    ComboBox resolution = new ComboBox();
    ComboBox fps = new ComboBox();
    TextBox bitrate = new TextBox();
    CheckBox startup = new CheckBox();
    CheckBox autostart = new CheckBox();
    CheckBox minimized = new CheckBox();
    Button start = new Button();
    Button stop = new Button();
    Button save = new Button();
    TextBox log = new TextBox();
    Label status = new Label();
    NotifyIcon tray;
    const string RegPath = @"Software\PadDisplay";
    const string Engine = @"\\wsl$\Ubuntu\home\josh\ipad-display\tools\launch_windows.ps1";

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new PadDisplayLauncher(Array.Exists(args, x => x == "--autostart")));
    }

    PadDisplayLauncher(bool launchedAtLogin)
    {
        Text = "PadDisplay";
        Width = 760; Height = 560;
        MinimumSize = new Size(680, 500);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9);

        var top = new TableLayoutPanel();
        top.Dock = DockStyle.Top; top.Height = 180;
        top.Padding = new Padding(12); top.ColumnCount = 4; top.RowCount = 5;
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));

        display.DropDownStyle = ComboBoxStyle.DropDownList; display.Dock = DockStyle.Fill;
        resolution.DropDownStyle = ComboBoxStyle.DropDownList; resolution.Dock = DockStyle.Fill;
        resolution.Items.AddRange(new object[] {"1024x768","1280x960","1600x1200","2048x1536"});
        fps.DropDownStyle = ComboBoxStyle.DropDownList; fps.Dock = DockStyle.Fill;
        fps.Items.AddRange(new object[] {"60","30"});
        bitrate.Dock = DockStyle.Fill;

        AddRow(top,0,"Display",display,"Resolution",resolution);
        AddRow(top,1,"FPS",fps,"Bitrate",bitrate);

        startup.Text = "Start with Windows"; startup.AutoSize = true;
        autostart.Text = "Automatically start streaming"; autostart.AutoSize = true;
        minimized.Text = "Start minimized to tray"; minimized.AutoSize = true;
        top.Controls.Add(startup,0,2); top.SetColumnSpan(startup,2);
        top.Controls.Add(autostart,2,2); top.SetColumnSpan(autostart,2);
        top.Controls.Add(minimized,0,3); top.SetColumnSpan(minimized,2);

        var buttons = new FlowLayoutPanel(); buttons.Dock = DockStyle.Fill;
        start.Text="Start"; stop.Text="Stop"; save.Text="Save settings";
        start.Width=90; stop.Width=90; save.Width=110; stop.Enabled=false;
        buttons.Controls.Add(start); buttons.Controls.Add(stop); buttons.Controls.Add(save);
        top.Controls.Add(buttons,2,3); top.SetColumnSpan(buttons,2);

        status.Text="Stopped"; status.Dock=DockStyle.Top; status.Height=28; status.Padding=new Padding(12,5,0,0);
        log.Dock=DockStyle.Fill; log.Multiline=true; log.ReadOnly=true; log.ScrollBars=ScrollBars.Vertical;
        log.Font=new Font("Consolas",9); log.BackColor=Color.Black; log.ForeColor=Color.Gainsboro;

        Controls.Add(log); Controls.Add(status); Controls.Add(top);

        PopulateDisplays(); LoadSettings();

        resolution.SelectedIndexChanged += delegate {
            string r = Convert.ToString(resolution.SelectedItem);
            bitrate.Text = r=="1024x768"?"4M":r=="1280x960"?"6M":r=="1600x1200"?"10M":"16M";
        };
        start.Click += delegate { StartEngine(); };
        stop.Click += delegate { StopEngine(); };
        save.Click += delegate { SaveSettings(); ApplyStartup(); Append("Settings saved."); };

        tray = new NotifyIcon(); tray.Visible=true; tray.Text="PadDisplay"; tray.Icon=SystemIcons.Application;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open",null,delegate { Show(); WindowState=FormWindowState.Normal; Activate(); });
        menu.Items.Add("Start",null,delegate { StartEngine(); });
        menu.Items.Add("Stop",null,delegate { StopEngine(); });
        menu.Items.Add("Exit",null,delegate { StopEngine(); tray.Visible=false; Environment.Exit(0); });
        tray.ContextMenuStrip=menu;
        tray.DoubleClick += delegate { Show(); WindowState=FormWindowState.Normal; Activate(); };

        FormClosing += delegate(object sender, FormClosingEventArgs e) { e.Cancel=true; Hide(); };
        Resize += delegate { if (WindowState==FormWindowState.Minimized && minimized.Checked) Hide(); };

        Shown += delegate {
            if (launchedAtLogin || minimized.Checked) { WindowState=FormWindowState.Minimized; Hide(); }
            if (launchedAtLogin && autostart.Checked) StartEngine();
        };
    }

    static void AddRow(TableLayoutPanel p,int row,string a,Control ac,string b,Control bc)
    {
        p.Controls.Add(new Label {Text=a,AutoSize=true,Anchor=AnchorStyles.Left},0,row);
        p.Controls.Add(ac,1,row);
        p.Controls.Add(new Label {Text=b,AutoSize=true,Anchor=AnchorStyles.Left},2,row);
        p.Controls.Add(bc,3,row);
    }

    void PopulateDisplays()
    {
        var screens=Screen.AllScreens;
        for(int i=0;i<screens.Length;i++)
            display.Items.Add(i+": "+screens[i].DeviceName+" "+screens[i].Bounds.Width+"x"+screens[i].Bounds.Height+(screens[i].Primary?" [primary]":""));
        int pick=0;
        for(int i=screens.Length-1;i>=0;i--) if(!screens[i].Primary){pick=i;break;}
        if(display.Items.Count>0) display.SelectedIndex=pick;
    }

    string ReadReg(string name,string fallback)
    {
        using(var k=Registry.CurrentUser.CreateSubKey(RegPath))
        {
            var v=k.GetValue(name); return v==null?fallback:Convert.ToString(v);
        }
    }

    void LoadSettings()
    {
        int n;
        if(int.TryParse(ReadReg("DisplayIndex","-1"),out n) && n>=0 && n<display.Items.Count) display.SelectedIndex=n;
        string r=ReadReg("Resolution","1280x960");
        resolution.SelectedItem=resolution.Items.Contains(r)?r:"1280x960";
        string f=ReadReg("Fps","60"); fps.SelectedItem=f=="30"?"30":"60";
        bitrate.Text=ReadReg("Bitrate","6M");
        startup.Checked=ReadReg("StartWithWindows","False")=="True";
        autostart.Checked=ReadReg("AutoStartStream","False")=="True";
        minimized.Checked=ReadReg("StartMinimized","False")=="True";
    }

    void SaveSettings()
    {
        using(var k=Registry.CurrentUser.CreateSubKey(RegPath))
        {
            k.SetValue("DisplayIndex",display.SelectedIndex);
            k.SetValue("Resolution",Convert.ToString(resolution.SelectedItem));
            k.SetValue("Fps",Convert.ToString(fps.SelectedItem));
            k.SetValue("Bitrate",bitrate.Text.Trim());
            k.SetValue("StartWithWindows",startup.Checked);
            k.SetValue("AutoStartStream",autostart.Checked);
            k.SetValue("StartMinimized",minimized.Checked);
        }
    }

    void ApplyStartup()
    {
        try
        {
            using(var k=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            {
                if(startup.Checked)
                    k.SetValue("PadDisplay", "\"" + Application.ExecutablePath + "\" --autostart");
                else
                    k.DeleteValue("PadDisplay", false);
            }
        }
        catch(Exception ex){Append("Startup registration: "+ex.Message);}
    }

    bool EngineTaskExists()
    {
        try
        {
            var psi=new ProcessStartInfo("schtasks.exe","/Query /TN \"" + TaskName + "\"");
            psi.UseShellExecute=false; psi.CreateNoWindow=true;
            var p=Process.Start(psi); p.WaitForExit();
            return p.ExitCode==0;
        }
        catch { return false; }
    }

    bool EnsureEngineTask()
    {
        if(EngineTaskExists()) return true;
        if(!File.Exists(TaskSetup))
        {
            MessageBox.Show("Engine task installer not found:\r\n"+TaskSetup);
            return false;
        }

        var answer=MessageBox.Show(
            "PadDisplay needs one administrator approval to install its privileged streaming engine.\r\n\r\nAfter this, starting PadDisplay will not ask for UAC again.",
            "PadDisplay setup", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
        if(answer!=DialogResult.OK) return false;

        try
        {
            var psi=new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + TaskSetup + "\"");
            psi.UseShellExecute=true; psi.Verb="runas";
            var p=Process.Start(psi); p.WaitForExit();
            return p.ExitCode==0 && EngineTaskExists();
        }
        catch(Exception ex)
        {
            Append("Engine setup: "+ex.Message);
            return false;
        }
    }

    void StartEngine()
    {
        SaveSettings();
        if(!EnsureEngineTask()) return;
        try
        {
            var p=Process.Start(new ProcessStartInfo("schtasks.exe",
                "/Run /TN \"" + TaskName + "\""){UseShellExecute=false,CreateNoWindow=true});
            p.WaitForExit();
            if(p.ExitCode!=0) throw new Exception("Task Scheduler returned "+p.ExitCode);
            status.Text="Running";
            start.Enabled=false;
            stop.Enabled=true;
            Append("PadDisplay engine started without UAC.");
        }
        catch(Exception ex)
        {
            Append("Start failed: "+ex.Message);
            status.Text="Stopped";
        }
    }

    void StopEngine()
    {
        try
        {
            var p=Process.Start(new ProcessStartInfo("schtasks.exe",
                "/End /TN \"" + TaskName + "\""){UseShellExecute=false,CreateNoWindow=true});
            p.WaitForExit();
        }
        catch {}
        status.Text="Stopped";
        start.Enabled=true;
        stop.Enabled=false;
        Append("PadDisplay engine stopped.");
    }

    void Append(string text)
    {
        if(InvokeRequired){BeginInvoke((Action<string>)Append,text);return;}
        log.AppendText(text+Environment.NewLine); log.SelectionStart=log.TextLength; log.ScrollToCaret();
    }
}
