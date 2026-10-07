using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

class PadDisplayReceiver : Form
{
    const byte VIDEO_H264 = 0x01;
    const byte CONFIG = 0x03;
    const byte DISCONNECT = 0x04;
    const byte TOUCH_V1 = 0x10;

    readonly PictureBox picture = new PictureBox();
    readonly Label overlay = new Label();
    readonly Label status = new Label();
    readonly Button fullscreen = new Button();
    readonly Button stop = new Button();
    TcpListener listener;
    TcpClient client;
    NetworkStream stream;
    Process decoder;
    Thread acceptThread;
    Thread receiveThread;
    Thread frameThread;
    readonly object sendLock = new object();
    volatile bool running = true;
    volatile bool connected = false;
    int frameWidth = 1280;
    int frameHeight = 960;
    bool dragging = false;
    FormBorderStyle savedBorder;
    Rectangle savedBounds;

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new PadDisplayReceiver());
    }

    PadDisplayReceiver()
    {
        Text = "PadDisplay Receiver";
        Width = 1100;
        Height = 760;
        MinimumSize = new Size(640, 480);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.Black;
        KeyPreview = true;
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Maximized;
        TopMost = true;

        picture.Dock = DockStyle.Fill;
        picture.BackColor = Color.Black;
        picture.SizeMode = PictureBoxSizeMode.Zoom;

        overlay.Dock = DockStyle.Fill;
        overlay.BackColor = Color.Black;
        overlay.ForeColor = Color.White;
        overlay.TextAlign = ContentAlignment.MiddleCenter;
        overlay.Font = new Font("Segoe UI", 24, FontStyle.Regular);
        overlay.Text = "PadDisplay Receiver\r\n\r\nWaiting for host connection\r\nTCP 4822";

        var bar = new FlowLayoutPanel();
        bar.Dock = DockStyle.Top;
        bar.Height = 38;
        bar.Padding = new Padding(6, 5, 6, 4);

        status.AutoSize = true;
        status.Text = "Listening on TCP 4822...";
        status.Padding = new Padding(4, 5, 12, 0);

        fullscreen.Text = "Fullscreen";
        fullscreen.AutoSize = true;
        stop.Text = "Disconnect";
        stop.AutoSize = true;
        stop.Enabled = false;

        bar.Controls.Add(status);
        bar.Controls.Add(fullscreen);
        bar.Controls.Add(stop);
        Controls.Add(picture);
        Controls.Add(overlay);
        Controls.Add(bar);
        overlay.BringToFront();
        bar.BringToFront();

        picture.MouseDown += PictureMouseDown;
        picture.MouseMove += PictureMouseMove;
        picture.MouseUp += PictureMouseUp;
        fullscreen.Click += delegate { ToggleFullscreen(); };
        stop.Click += delegate { DisconnectClient(); };
        KeyDown += delegate(object sender, KeyEventArgs e) {
            if (e.KeyCode == Keys.F11) { ToggleFullscreen(); e.Handled = true; }
            if (e.KeyCode == Keys.Escape && FormBorderStyle == FormBorderStyle.None) {
                ToggleFullscreen(); e.Handled = true;
            }
        };
        FormClosing += delegate {
            running = false;
            DisconnectClient();
            try { if (listener != null) listener.Stop(); } catch {}
        };

        acceptThread = new Thread(AcceptLoop);
        acceptThread.IsBackground = true;
        acceptThread.Start();
    }

    void AcceptLoop()
    {
        try
        {
            listener = new TcpListener(IPAddress.Any, 4822);
            listener.Start();
            while (running)
            {
                SetStatus("Listening on TCP 4822...");
                SetOverlay("PadDisplay Receiver\\r\\n\\r\\nWaiting for host connection\\r\\nTCP 4822");
                var c = listener.AcceptTcpClient();
                if (!running) break;
                DisconnectClient();
                client = c;
                client.NoDelay = true;
                stream = client.GetStream();
                connected = true;
                SetStopEnabled(true);
                SetStatus("Host connected - waiting for CONFIG...");
                SetOverlay("Host connected\r\nWaiting for stream...");
                SendHello();

                receiveThread = new Thread(ReceiveLoop);
                receiveThread.IsBackground = true;
                receiveThread.Start();
                receiveThread.Join();
                DisconnectClient();
            }
        }
        catch (SocketException)
        {
            if (running) SetStatus("Listener stopped unexpectedly.");
        }
        catch (Exception ex)
        {
            if (running) SetStatus("Listener error: " + ex.Message);
        }
    }

    void ReceiveLoop()
    {
        try
        {
            while (running && connected)
            {
                byte[] header = ReadExact(stream, 5);
                if (header == null) break;
                int length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
                byte type = header[4];
                if (length < 0 || length > 64 * 1024 * 1024) throw new IOException("Invalid packet length.");
                byte[] payload = ReadExact(stream, length);
                if (payload == null) break;

                if (type == CONFIG)
                {
                    string json = Encoding.UTF8.GetString(payload);
                    int w = JsonInt(json, "width", frameWidth);
                    int h = JsonInt(json, "height", frameHeight);
                    if (w > 0 && h > 0 && (w != frameWidth || h != frameHeight || decoder == null))
                    {
                        frameWidth = w;
                        frameHeight = h;
                        StartDecoder();
                    }
                    SetStatus("Connected • " + frameWidth + "x" + frameHeight + " • H.264");
                    SetOverlay(null);
                }
                else if (type == VIDEO_H264)
                {
                    if (decoder == null) StartDecoder();
                    decoder.StandardInput.BaseStream.Write(payload, 0, payload.Length);
                    decoder.StandardInput.BaseStream.Flush();
                }
                else if (type == DISCONNECT)
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            if (running) SetStatus("Connection ended: " + ex.Message);
        }
    }

    void StartDecoder()
    {
        StopDecoder();
        string ffmpeg = FindFfmpeg();
        if (ffmpeg == null)
            throw new FileNotFoundException("ffmpeg.exe was not found. Put it in PATH or next to PadDisplayReceiver.exe.");

        var psi = new ProcessStartInfo();
        psi.FileName = ffmpeg;
        psi.Arguments = "-hide_banner -loglevel error -fflags nobuffer -flags low_delay -f h264 -i pipe:0 -an -f rawvideo -pix_fmt bgra pipe:1";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        decoder = Process.Start(psi);

        frameThread = new Thread(FrameLoop);
        frameThread.IsBackground = true;
        frameThread.Start();
    }

    void FrameLoop()
    {
        int width = frameWidth;
        int height = frameHeight;
        int bytesPerFrame = width * height * 4;
        byte[] frame = new byte[bytesPerFrame];

        try
        {
            Stream output = decoder.StandardOutput.BaseStream;
            while (running && connected && decoder != null && !decoder.HasExited)
            {
                if (!ReadExactInto(output, frame, bytesPerFrame)) break;
                byte[] copy = new byte[bytesPerFrame];
                Buffer.BlockCopy(frame, 0, copy, 0, bytesPerFrame);
                ShowFrame(copy, width, height);
            }
        }
        catch {}
    }

    void ShowFrame(byte[] pixels, int width, int height)
    {
        if (IsDisposed) return;
        BeginInvoke((Action)delegate {
            try
            {
                var bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
                var rect = new Rectangle(0, 0, width, height);
                var data = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
                bmp.UnlockBits(data);
                var old = picture.Image;
                picture.Image = bmp;
                if (old != null) old.Dispose();
            }
            catch {}
        });
    }

    void SendHello()
    {
        string hello = "{\"protocol\":1,\"app\":\"windows-receiver\",\"build\":1,\"device\":\"Windows Receiver\",\"name\":\"" +
            Environment.MachineName.Replace("\"", "") + "\"}";
        SendPacket(CONFIG, Encoding.UTF8.GetBytes(hello));
    }

    void PictureMouseDown(object sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || !connected) return;
        dragging = true;
        SendTouch(0, e.Location);
    }

    void PictureMouseMove(object sender, MouseEventArgs e)
    {
        if (!dragging || !connected) return;
        SendTouch(1, e.Location);
    }

    void PictureMouseUp(object sender, MouseEventArgs e)
    {
        if (!dragging || !connected) return;
        SendTouch(2, e.Location);
        dragging = false;
    }

    void SendTouch(byte phase, Point p)
    {
        Rectangle area = GetDisplayedImageRectangle();
        if (area.Width <= 0 || area.Height <= 0) return;
        double nx = Math.Max(0.0, Math.Min(1.0, (p.X - area.Left) / (double)Math.Max(1, area.Width - 1)));
        double ny = Math.Max(0.0, Math.Min(1.0, (p.Y - area.Top) / (double)Math.Max(1, area.Height - 1)));
        ushort x = (ushort)Math.Round(nx * 65535.0);
        ushort y = (ushort)Math.Round(ny * 65535.0);

        byte[] payload = new byte[5];
        payload[0] = phase;
        payload[1] = (byte)(x >> 8);
        payload[2] = (byte)(x & 0xff);
        payload[3] = (byte)(y >> 8);
        payload[4] = (byte)(y & 0xff);
        SendPacket(TOUCH_V1, payload);
    }

    Rectangle GetDisplayedImageRectangle()
    {
        if (picture.Image == null) return picture.ClientRectangle;
        double imageAspect = picture.Image.Width / (double)picture.Image.Height;
        double boxAspect = picture.ClientSize.Width / (double)Math.Max(1, picture.ClientSize.Height);

        if (boxAspect > imageAspect)
        {
            int h = picture.ClientSize.Height;
            int w = (int)Math.Round(h * imageAspect);
            return new Rectangle((picture.ClientSize.Width - w) / 2, 0, w, h);
        }

        int ww = picture.ClientSize.Width;
        int hh = (int)Math.Round(ww / imageAspect);
        return new Rectangle(0, (picture.ClientSize.Height - hh) / 2, ww, hh);
    }

    void SendPacket(byte type, byte[] payload)
    {
        try
        {
            lock (sendLock)
            {
                if (stream == null || !connected) return;
                int len = payload == null ? 0 : payload.Length;
                byte[] header = new byte[] {
                    (byte)(len >> 24), (byte)(len >> 16), (byte)(len >> 8), (byte)len, type
                };
                stream.Write(header, 0, header.Length);
                if (len > 0) stream.Write(payload, 0, len);
                stream.Flush();
            }
        }
        catch {}
    }

    void DisconnectClient()
    {
        connected = false;
        dragging = false;
        try { if (stream != null) stream.Close(); } catch {}
        try { if (client != null) client.Close(); } catch {}
        stream = null;
        client = null;
        StopDecoder();
        SetStopEnabled(false);
        if (running) {
            SetStatus("Listening on TCP 4822...");
            SetOverlay("PadDisplay Receiver\\r\\n\\r\\nWaiting for host connection\\r\\nTCP 4822");
        }
    }

    void StopDecoder()
    {
        try
        {
            if (decoder != null && !decoder.HasExited)
            {
                try { decoder.StandardInput.Close(); } catch {}
                if (!decoder.WaitForExit(500)) decoder.Kill();
            }
        }
        catch {}
        decoder = null;
    }

    void ToggleFullscreen()
    {
        if (FormBorderStyle != FormBorderStyle.None)
        {
            savedBorder = FormBorderStyle;
            savedBounds = Bounds;
            FormBorderStyle = FormBorderStyle.None;
            WindowState = FormWindowState.Normal;
            Bounds = Screen.FromControl(this).Bounds;
            fullscreen.Text = "Windowed";
        }
        else
        {
            FormBorderStyle = savedBorder == FormBorderStyle.None ? FormBorderStyle.Sizable : savedBorder;
            Bounds = savedBounds;
            fullscreen.Text = "Fullscreen";
        }
    }

    static byte[] ReadExact(Stream s, int length)
    {
        if (length == 0) return new byte[0];
        byte[] data = new byte[length];
        return ReadExactInto(s, data, length) ? data : null;
    }

    static bool ReadExactInto(Stream s, byte[] buffer, int length)
    {
        int offset = 0;
        while (offset < length)
        {
            int n = s.Read(buffer, offset, length - offset);
            if (n <= 0) return false;
            offset += n;
        }
        return true;
    }

    static int JsonInt(string json, string key, int fallback)
    {
        string token = "\"" + key + "\":";
        int p = json.IndexOf(token, StringComparison.Ordinal);
        if (p < 0) return fallback;
        p += token.Length;
        while (p < json.Length && Char.IsWhiteSpace(json[p])) p++;
        int end = p;
        while (end < json.Length && (Char.IsDigit(json[end]) || json[end] == '-')) end++;
        int value;
        return Int32.TryParse(json.Substring(p, end - p), out value) ? value : fallback;
    }

    static string FindFfmpeg()
    {
        string local = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ffmpeg.exe");
        if (File.Exists(local)) return local;
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in path.Split(';'))
        {
            try
            {
                string candidate = Path.Combine(dir.Trim(), "ffmpeg.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch {}
        }
        return null;
    }

    void SetOverlay(string text)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke((Action<string>)SetOverlay, text); return; }
        if (String.IsNullOrEmpty(text))
        {
            overlay.Visible = false;
            picture.BringToFront();
        }
        else
        {
            overlay.Text = text;
            overlay.Visible = true;
            overlay.BringToFront();
            Controls[Controls.Count - 1].BringToFront();
        }
    }

    void SetStatus(string text)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke((Action<string>)SetStatus, text); return; }
        status.Text = text;
    }

    void SetStopEnabled(bool enabled)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke((Action<bool>)SetStopEnabled, enabled); return; }
        stop.Enabled = enabled;
    }
}
