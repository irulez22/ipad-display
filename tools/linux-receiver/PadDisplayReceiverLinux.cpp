#include <SDL2/SDL.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static constexpr uint8_t VIDEO_H264=0x01, CONFIG=0x03, DISCONNECT=0x04;
static constexpr uint8_t MOUSE_V1=0x12, KEYBOARD_V1=0x13;
static constexpr uint8_t AUDIO_PCM=0x20, AUDIO_PCM_V2=0x21;

static std::atomic<bool> running{true}, connected{false};
static int client_fd=-1;
static std::mutex send_mtx, log_mtx;
static std::ofstream log_file;
static std::mutex video_mtx, audio_mtx;
static std::condition_variable video_cv;
static std::deque<std::vector<uint8_t>> video_q;
static std::deque<uint8_t> audio_q;
static constexpr size_t VIDEO_Q_MAX=8;
static constexpr size_t AUDIO_MAX=48000*4*120/1000;
static std::atomic<uint64_t> video_packets{0}, video_bytes{0}, frames{0};
static std::atomic<uint64_t> audio_packets{0}, audio_underruns{0};

static SDL_Window* window_=nullptr;
static SDL_Renderer* renderer_=nullptr;
static SDL_Texture* texture_=nullptr;
static SDL_AudioDeviceID audio_dev=0;
static bool fullscreen_=true;
static int stream_w=1366, stream_h=768;
static AVBufferRef* hw_device=nullptr;
static AVPixelFormat hw_fmt=AV_PIX_FMT_NONE;

static void Log(const std::string& s) {
    std::lock_guard<std::mutex> lock(log_mtx);
    if (!log_file.is_open()) return;
    auto t=std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    char b[64]{};
    std::tm tm{};
    localtime_r(&t,&tm);
    std::strftime(b,sizeof(b),"%F %T",&tm);
    log_file<<b<<" "<<s<<"\n";
    log_file.flush();
}
static bool ReadExact(int fd, void* out, size_t n) {
    auto* p=static_cast<uint8_t*>(out); size_t off=0;
    while(off<n && running) {
        ssize_t r=recv(fd,p+off,n-off,0);
        if(r<=0) return false;
        off+=(size_t)r;
    }
    return off==n;
}
static bool SendAll(int fd,const uint8_t* p,size_t n) {
    size_t off=0;
    while(off<n) {
        ssize_t w=send(fd,p+off,n-off,MSG_NOSIGNAL);
        if(w<=0) return false;
        off+=(size_t)w;
    }
    return true;
}
static bool SendPacket(uint8_t type,const uint8_t* p,uint32_t n) {
    std::lock_guard<std::mutex> lock(send_mtx);
    if(client_fd<0) return false;
    uint8_t h[5]={uint8_t(n>>24),uint8_t(n>>16),uint8_t(n>>8),uint8_t(n),type};
    return SendAll(client_fd,h,5) && (!n || SendAll(client_fd,p,n));
}
static int Listen(uint16_t port) {
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if(fd<0) return -1;
    int one=1; setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    sockaddr_in a{}; a.sin_family=AF_INET; a.sin_addr.s_addr=htonl(INADDR_ANY); a.sin_port=htons(port);
    if(bind(fd,(sockaddr*)&a,sizeof(a))<0 || listen(fd,2)<0){close(fd);return -1;}
    return fd;
}
static AVPixelFormat GetHwFormat(AVCodecContext*,const AVPixelFormat* fmts){
    for(auto p=fmts;*p!=AV_PIX_FMT_NONE;++p) if(*p==hw_fmt) return *p;
    return fmts[0];
}

struct Decoder {
    AVCodecContext* ctx=nullptr;
    AVCodecParserContext* parser=nullptr;
    AVFrame *frame=nullptr,*sw=nullptr;
    AVPacket* pkt=nullptr;
    SwsContext* sws=nullptr;
    bool hw=false;

    bool Init(){
        const AVCodec* codec=avcodec_find_decoder(AV_CODEC_ID_H264);
        if(!codec) return false;
        ctx=avcodec_alloc_context3(codec);
        parser=av_parser_init(AV_CODEC_ID_H264);
        frame=av_frame_alloc(); sw=av_frame_alloc(); pkt=av_packet_alloc();
        if(!ctx||!parser||!frame||!sw||!pkt) return false;
        for(int i=0;;++i){
            const AVCodecHWConfig* c=avcodec_get_hw_config(codec,i);
            if(!c) break;
            if((c->methods&AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) &&
               c->device_type==AV_HWDEVICE_TYPE_VAAPI){
                hw_fmt=c->pix_fmt;
                if(av_hwdevice_ctx_create(&hw_device,AV_HWDEVICE_TYPE_VAAPI,nullptr,nullptr,0)>=0){
                    ctx->hw_device_ctx=av_buffer_ref(hw_device);
                    ctx->get_format=GetHwFormat; hw=true; Log("decoder: VA-API enabled");
                }
                break;
            }
        }
        if(!hw) Log("decoder: software H.264 fallback");
        ctx->thread_count=hw?1:2;
        ctx->flags|=AV_CODEC_FLAG_LOW_DELAY;
        return avcodec_open2(ctx,codec,nullptr)>=0;
    }
    ~Decoder(){
        if(sws) sws_freeContext(sws);
        av_packet_free(&pkt); av_frame_free(&sw); av_frame_free(&frame);
        if(parser) av_parser_close(parser);
        avcodec_free_context(&ctx);
    }
    void Present(AVFrame* src){
        AVFrame* use=src;
        if(src->format==hw_fmt){
            av_frame_unref(sw);
            if(av_hwframe_transfer_data(sw,src,0)<0) return;
            use=sw;
        }
        if(!texture_ || use->width!=stream_w || use->height!=stream_h){
            stream_w=use->width; stream_h=use->height;
            if(texture_) SDL_DestroyTexture(texture_);
            texture_=SDL_CreateTexture(renderer_,SDL_PIXELFORMAT_IYUV,SDL_TEXTUREACCESS_STREAMING,stream_w,stream_h);
            Log("video mode: "+std::to_string(stream_w)+"x"+std::to_string(stream_h));
        }
        if(!texture_) return;
        if(use->format==AV_PIX_FMT_YUV420P){
            SDL_UpdateYUVTexture(texture_,nullptr,use->data[0],use->linesize[0],
                                 use->data[1],use->linesize[1],use->data[2],use->linesize[2]);
        } else {
            sws=sws_getCachedContext(sws,use->width,use->height,(AVPixelFormat)use->format,
                                     use->width,use->height,AV_PIX_FMT_YUV420P,SWS_FAST_BILINEAR,nullptr,nullptr,nullptr);
            if(!sws) return;
            std::vector<uint8_t> buf(av_image_get_buffer_size(AV_PIX_FMT_YUV420P,use->width,use->height,1));
            uint8_t* dst[4]{}; int lines[4]{};
            av_image_fill_arrays(dst,lines,buf.data(),AV_PIX_FMT_YUV420P,use->width,use->height,1);
            sws_scale(sws,use->data,use->linesize,0,use->height,dst,lines);
            SDL_UpdateYUVTexture(texture_,nullptr,dst[0],lines[0],dst[1],lines[1],dst[2],lines[2]);
        }
        SDL_RenderClear(renderer_); SDL_RenderCopy(renderer_,texture_,nullptr,nullptr); SDL_RenderPresent(renderer_);
        ++frames;
    }
    void Feed(const uint8_t* data,size_t bytes){
        while(bytes){
            uint8_t* out=nullptr; int out_n=0;
            int used=av_parser_parse2(parser,ctx,&out,&out_n,data,(int)bytes,AV_NOPTS_VALUE,AV_NOPTS_VALUE,0);
            if(used<0) return;
            data+=used; bytes-=used;
            if(!out_n) continue;
            av_packet_unref(pkt); pkt->data=out; pkt->size=out_n;
            if(avcodec_send_packet(ctx,pkt)<0) continue;
            while(avcodec_receive_frame(ctx,frame)==0){Present(frame);av_frame_unref(frame);}
        }
    }
};

static void DecodeThread(){
    Decoder d;
    if(!d.Init()){Log("decoder init failed");running=false;return;}
    while(running){
        std::vector<uint8_t> chunk;
        {
            std::unique_lock<std::mutex> lock(video_mtx);
            video_cv.wait(lock,[]{return !running||!video_q.empty();});
            if(!running) break;
            chunk=std::move(video_q.front()); video_q.pop_front();
        }
        video_cv.notify_all();
        d.Feed(chunk.data(),chunk.size());
    }
}
static void AudioCallback(void*,Uint8* stream,int len){
    memset(stream,0,len);
    std::lock_guard<std::mutex> lock(audio_mtx);
    size_t n=std::min<size_t>(len,audio_q.size()); n-=n%4;
    for(size_t i=0;i<n;++i){stream[i]=audio_q.front();audio_q.pop_front();}
    if(n<(size_t)len) ++audio_underruns;
}
static void AudioThread(){
    int listener=Listen(4824);
    if(listener<0){Log("audio listen failed");return;}
    while(running){
        fd_set set; FD_ZERO(&set); FD_SET(listener,&set); timeval tv{1,0};
        int ready=select(listener+1,&set,nullptr,nullptr,&tv);
        if(!running) break;
        if(ready<=0) continue;
        int fd=accept(listener,nullptr,nullptr);
        if(fd<0) continue;
        Log("audio connected");
        while(running){
            uint8_t h[5]; if(!ReadExact(fd,h,5)) break;
            uint32_t n=(uint32_t(h[0])<<24)|(uint32_t(h[1])<<16)|(uint32_t(h[2])<<8)|h[3];
            if(n>4*1024*1024) break;
            std::vector<uint8_t> p(n); if(n&&!ReadExact(fd,p.data(),n)) break;
            size_t off=0;
            if(h[4]==AUDIO_PCM_V2 && n>=12) off=12;
            else if(h[4]!=AUDIO_PCM) continue;
            std::lock_guard<std::mutex> lock(audio_mtx);
            size_t add=p.size()-off;
            while(audio_q.size()+add>AUDIO_MAX && audio_q.size()>=4)
                for(int i=0;i<4;++i) audio_q.pop_front();
            audio_q.insert(audio_q.end(),p.begin()+off,p.end()); ++audio_packets;
        }
        close(fd); Log("audio disconnected");
    }
    close(listener);
}
static void NetworkThread(){
    int listener=Listen(4822);
    if(listener<0){Log("video listen failed");running=false;return;}
    while(running){
        fd_set set; FD_ZERO(&set); FD_SET(listener,&set); timeval tv{1,0};
        int ready=select(listener+1,&set,nullptr,nullptr,&tv);
        if(!running) break;
        if(ready<=0) continue;
        int fd=accept(listener,nullptr,nullptr);
        if(fd<0) continue;
        int one=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
        {std::lock_guard<std::mutex> lock(send_mtx);client_fd=fd;}
        connected=true;
        const std::string hello="{\"protocol\":1,\"client\":\"linux\",\"session_mode\":\"thin_client\","
            "\"video\":\"h264\",\"audio_pcm_v2\":true,\"audio_port\":4824,"
            "\"mouse_v1\":true,\"keyboard_v1\":true,\"vaapi\":true}";
        SendPacket(CONFIG,(const uint8_t*)hello.data(),(uint32_t)hello.size());
        Log("host connected");
        while(running){
            uint8_t h[5]; if(!ReadExact(fd,h,5)) break;
            uint32_t n=(uint32_t(h[0])<<24)|(uint32_t(h[1])<<16)|(uint32_t(h[2])<<8)|h[3];
            if(n>8*1024*1024) break;
            std::vector<uint8_t> p(n); if(n&&!ReadExact(fd,p.data(),n)) break;
            if(h[4]==DISCONNECT) break;
            if(h[4]==VIDEO_H264){
                std::unique_lock<std::mutex> lock(video_mtx);
                video_cv.wait(lock,[]{return !running||video_q.size()<VIDEO_Q_MAX;});
                if(!running) break;
                video_q.emplace_back(std::move(p)); ++video_packets; video_bytes+=n;
                lock.unlock(); video_cv.notify_one();
            }
        }
        connected=false;
        {std::lock_guard<std::mutex> lock(send_mtx);if(client_fd==fd)client_fd=-1;}
        close(fd); Log("host disconnected");
    }
    close(listener);
}
static uint16_t Norm(int v,int maxv){
    if(maxv<=1) return 0; v=std::max(0,std::min(v,maxv-1));
    return (uint16_t)((uint64_t)v*65535/(uint64_t)(maxv-1));
}
static void SendMouse(uint8_t action,uint8_t button,int x,int y,int wheel){
    int w=1,h=1; SDL_GetWindowSize(window_,&w,&h);
    uint16_t nx=Norm(x,w),ny=Norm(y,h);
    int16_t wd=(int16_t)std::max(-32768,std::min(32767,wheel));
    uint16_t uw=(uint16_t)wd;
    uint8_t p[8]={action,button,uint8_t(nx>>8),uint8_t(nx),uint8_t(ny>>8),uint8_t(ny),uint8_t(uw>>8),uint8_t(uw)};
    SendPacket(MOUSE_V1,p,sizeof(p));
}
static uint16_t WinVk(SDL_Keycode k){
    if(k>=SDLK_a&&k<=SDLK_z) return uint16_t('A'+(k-SDLK_a));
    if(k>=SDLK_0&&k<=SDLK_9) return uint16_t('0'+(k-SDLK_0));
    switch(k){
        case SDLK_RETURN:return 0x0D; case SDLK_ESCAPE:return 0x1B; case SDLK_BACKSPACE:return 0x08;
        case SDLK_TAB:return 0x09; case SDLK_SPACE:return 0x20; case SDLK_LEFT:return 0x25;
        case SDLK_UP:return 0x26; case SDLK_RIGHT:return 0x27; case SDLK_DOWN:return 0x28;
        case SDLK_DELETE:return 0x2E; case SDLK_HOME:return 0x24; case SDLK_END:return 0x23;
        case SDLK_PAGEUP:return 0x21; case SDLK_PAGEDOWN:return 0x22;
        case SDLK_LSHIFT:case SDLK_RSHIFT:return 0x10; case SDLK_LCTRL:case SDLK_RCTRL:return 0x11;
        case SDLK_LALT:case SDLK_RALT:return 0x12; case SDLK_LGUI:case SDLK_RGUI:return 0x5B;
        case SDLK_F1:return 0x70;case SDLK_F2:return 0x71;case SDLK_F3:return 0x72;case SDLK_F4:return 0x73;
        case SDLK_F5:return 0x74;case SDLK_F6:return 0x75;case SDLK_F7:return 0x76;case SDLK_F8:return 0x77;
        case SDLK_F9:return 0x78;case SDLK_F10:return 0x79;case SDLK_F11:return 0x7A;case SDLK_F12:return 0x7B;
        default:return 0;
    }
}
static void SendKey(const SDL_KeyboardEvent& e,bool up){
    uint16_t vk=WinVk(e.keysym.sym); if(!vk) return;
    uint16_t sc=(uint16_t)e.keysym.scancode;
    uint8_t p[6]={uint8_t(up?1:0),uint8_t(vk>>8),uint8_t(vk),uint8_t(sc>>8),uint8_t(sc),0};
    SendPacket(KEYBOARD_V1,p,sizeof(p));
}
int main(){
    const char* home=getenv("HOME");
    std::string state=home?std::string(home)+"/.local/state/paddisplay":"/tmp/paddisplay";
    if(home){mkdir((std::string(home)+"/.local").c_str(),0755);mkdir((std::string(home)+"/.local/state").c_str(),0755);}
    mkdir(state.c_str(),0755); log_file.open(state+"/receiver.log",std::ios::app);
    if(SDL_Init(SDL_INIT_VIDEO|SDL_INIT_AUDIO|SDL_INIT_EVENTS)!=0){fprintf(stderr,"SDL init failed: %s\n",SDL_GetError());return 1;}
    window_=SDL_CreateWindow("PadDisplay Linux Client",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,1366,768,
                             SDL_WINDOW_SHOWN|SDL_WINDOW_RESIZABLE|SDL_WINDOW_FULLSCREEN_DESKTOP);
    renderer_=SDL_CreateRenderer(window_,-1,SDL_RENDERER_ACCELERATED|SDL_RENDERER_PRESENTVSYNC);
    if(!window_||!renderer_){fprintf(stderr,"SDL video failed: %s\n",SDL_GetError());return 1;}
    SDL_AudioSpec want{},got{}; want.freq=48000; want.format=AUDIO_S16LSB; want.channels=2; want.samples=1024; want.callback=AudioCallback;
    audio_dev=SDL_OpenAudioDevice(nullptr,0,&want,&got,0);
    if(audio_dev) SDL_PauseAudioDevice(audio_dev,0); else Log(std::string("audio open failed: ")+SDL_GetError());
    std::thread net(NetworkThread),dec(DecodeThread),aud(AudioThread);
    auto last=std::chrono::steady_clock::now();
    while(running){
        SDL_Event e{};
        if(SDL_WaitEventTimeout(&e,5)){
            if(e.type==SDL_QUIT) running=false;
            else if(e.type==SDL_KEYDOWN||e.type==SDL_KEYUP){
                bool up=e.type==SDL_KEYUP; SDL_Keymod mods=SDL_GetModState();
                if(!up&&e.key.keysym.sym==SDLK_q&&(mods&KMOD_CTRL)&&(mods&KMOD_SHIFT)) running=false;
                else if(!up&&e.key.keysym.sym==SDLK_F11){fullscreen_=!fullscreen_;SDL_SetWindowFullscreen(window_,fullscreen_?SDL_WINDOW_FULLSCREEN_DESKTOP:0);}
                else if(!up&&e.key.keysym.sym==SDLK_ESCAPE&&fullscreen_){fullscreen_=false;SDL_SetWindowFullscreen(window_,0);}
                else SendKey(e.key,up);
            } else if(e.type==SDL_MOUSEMOTION) SendMouse(0,0,e.motion.x,e.motion.y,0);
            else if(e.type==SDL_MOUSEBUTTONDOWN||e.type==SDL_MOUSEBUTTONUP){
                uint8_t b=e.button.button==SDL_BUTTON_LEFT?1:e.button.button==SDL_BUTTON_RIGHT?2:e.button.button==SDL_BUTTON_MIDDLE?3:0;
                if(b) SendMouse(e.type==SDL_MOUSEBUTTONDOWN?1:2,b,e.button.x,e.button.y,0);
            } else if(e.type==SDL_MOUSEWHEEL){
                int x=0,y=0;SDL_GetMouseState(&x,&y);SendMouse(3,0,x,y,e.wheel.y*120);
            }
        }
        auto now=std::chrono::steady_clock::now();
        if(now-last>=std::chrono::seconds(5)){
            Log("health connected="+std::to_string(connected.load())+
                " video_packets="+std::to_string(video_packets.load())+
                " video_bytes="+std::to_string(video_bytes.load())+
                " frames="+std::to_string(frames.load())+
                " audio_packets="+std::to_string(audio_packets.load())+
                " audio_underruns="+std::to_string(audio_underruns.load()));
            last=now;
        }
    }
    if(client_fd>=0) shutdown(client_fd,SHUT_RDWR);
    video_cv.notify_all();
    net.join(); dec.join(); aud.join();
    if(audio_dev) SDL_CloseAudioDevice(audio_dev);
    if(texture_) SDL_DestroyTexture(texture_);
    if(renderer_) SDL_DestroyRenderer(renderer_);
    if(window_) SDL_DestroyWindow(window_);
    if(hw_device) av_buffer_unref(&hw_device);
    SDL_Quit();
    return 0;
}
