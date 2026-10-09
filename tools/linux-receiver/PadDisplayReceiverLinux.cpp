#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <SDL2/SDL_syswm.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#define GL_GLEXT_PROTOTYPES
#include <SDL2/SDL_opengl.h>
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
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <deque>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static constexpr uint8_t VIDEO_H264=0x01, CONFIG=0x03, DISCONNECT=0x04;
static constexpr uint8_t MOUSE_V1=0x12, KEYBOARD_V1=0x13;
static constexpr uint8_t AUDIO_PCM=0x20, AUDIO_PCM_V2=0x21, AUDIO_FORMAT=0x22;

static std::atomic<bool> running{true}, connected{false};
static int client_fd=-1;
static std::mutex send_mtx, log_mtx;
static std::ofstream log_file;
static std::mutex video_mtx;
static std::condition_variable video_cv;
static std::deque<std::vector<uint8_t>> video_q;
static constexpr size_t VIDEO_Q_MAX=8;
static constexpr size_t AUDIO_MAX=48000*4*480/1000;
static constexpr size_t AUDIO_START_BYTES=48000*4*240/1000;
static std::atomic<bool> audio_playing{false};
static std::atomic<uint64_t> video_packets{0}, video_bytes{0}, decoded_frames{0}, frames{0};
static std::atomic<uint64_t> frame_fingerprint{0};
static std::atomic<uint64_t> frame_change_ppm{0};
static std::atomic<uint64_t> audio_packets{0}, audio_underruns{0}, audio_overflows{0};

static SDL_Window* window_=nullptr;
static SDL_GLContext gl_context=nullptr;
static GLuint gl_yuv_textures[3]={0,0,0};
static GLuint gl_yuv_program=0;
static int gl_tex_w=0, gl_tex_h=0;
static SDL_AudioDeviceID audio_dev=0;
static SDL_AudioStream* audio_stream=nullptr;
static bool fullscreen_=false;
static int windowed_x=SDL_WINDOWPOS_CENTERED, windowed_y=SDL_WINDOWPOS_CENTERED;
static int windowed_w=1366, windowed_h=768;
static int stream_w=1366, stream_h=768;
static AVBufferRef* hw_device=nullptr;
static AVPixelFormat hw_fmt=AV_PIX_FMT_NONE;
static TTF_Font* status_font=nullptr;
static std::mutex render_mtx;

struct PendingVideoFrame {
    int w=0, h=0;
    std::vector<uint8_t> y;
    std::vector<uint8_t> u;
    std::vector<uint8_t> v;
    bool ready=false;
};
static std::mutex pending_frame_mtx;
static PendingVideoFrame pending_frame;

static void DrawStatus(const char* message);
static bool RenderPendingFrame();

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
        fd_set set; FD_ZERO(&set); FD_SET(fd,&set); timeval tv{1,0};
        int ready=select(fd+1,&set,nullptr,nullptr,&tv);
        if(ready<0){ if(errno==EINTR) continue; return false; }
        if(!ready) continue;
        ssize_t r=recv(fd,p+off,n-off,0);
        if(r<0 && errno==EINTR) continue;
        if(r<=0) return false;
        off+=(size_t)r;
    }
    return off==n;
}
static bool SendAll(int fd,const uint8_t* p,size_t n) {
    size_t off=0;
    while(off<n) {
        ssize_t w=send(fd,p+off,n-off,MSG_NOSIGNAL);
        if(w<0 && errno==EINTR) continue;
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
static std::string DiscoveryReply(const std::string& request){
    const std::string prefix="PADDISPLAY_DISCOVER_V1 ";
    if(request.size()!=prefix.size()+32 || request.compare(0,prefix.size(),prefix)!=0) return {};
    const std::string nonce=request.substr(prefix.size());
    if(nonce.find_first_not_of("0123456789abcdef")!=std::string::npos) return {};
    char hostname[256]{};
    if(gethostname(hostname,sizeof(hostname)-1)!=0) return {};
    std::string name=hostname;
    for(char& c:name) if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||
                          (c>='0'&&c<='9')||c=='-'||c=='_'||c=='.')) c='_';
    return "PADDISPLAY_RECEIVER_V1 "+nonce+" "+name+" 4822 4824";
}

static void DiscoveryThread(){
    int fd=socket(AF_INET,SOCK_DGRAM,0);
    if(fd<0){Log("discovery socket failed");return;}
    sockaddr_in address{};address.sin_family=AF_INET;
    address.sin_addr.s_addr=htonl(INADDR_ANY);address.sin_port=htons(4821);
    if(bind(fd,(sockaddr*)&address,sizeof(address))<0){
        Log("discovery UDP 4821 unavailable");close(fd);return;
    }
    while(running){
        fd_set set;FD_ZERO(&set);FD_SET(fd,&set);timeval timeout{1,0};
        if(select(fd+1,&set,nullptr,nullptr,&timeout)<=0) continue;
        char request[128];sockaddr_in peer{};socklen_t size=sizeof(peer);
        ssize_t count=recvfrom(fd,request,sizeof(request),0,(sockaddr*)&peer,&size);
        if(count<=0) continue;
        std::string reply=DiscoveryReply(std::string(request,(size_t)count));
        if(!reply.empty()) sendto(fd,reply.data(),reply.size(),0,(sockaddr*)&peer,size);
    }
    close(fd);
}

static AVPixelFormat GetHwFormat(AVCodecContext*,const AVPixelFormat* fmts){
    for(auto p=fmts;*p!=AV_PIX_FMT_NONE;++p) if(*p==hw_fmt) return *p;
    return fmts[0];
}


static GLuint CompileShader(GLenum type,const char* source){
    GLuint shader=glCreateShader(type);
    if(!shader) return 0;
    glShaderSource(shader,1,&source,nullptr);
    glCompileShader(shader);
    GLint ok=0;
    glGetShaderiv(shader,GL_COMPILE_STATUS,&ok);
    if(!ok){
        char log[2048]{};
        GLsizei n=0;
        glGetShaderInfoLog(shader,sizeof(log)-1,&n,log);
        Log(std::string("OpenGL shader compile failed: ")+log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static bool InitYuvShader(){
    static const char* vertex_source=
        "#version 120\n"
        "void main(){\n"
        "  gl_Position=gl_Vertex;\n"
        "  gl_TexCoord[0]=gl_MultiTexCoord0;\n"
        "}\n";

    // NVENC/libx264 desktop video is normally limited-range YUV. BT.709 is the
    // right matrix for HD desktop content and keeps conversion on the GPU.
    static const char* fragment_source=
        "#version 120\n"
        "uniform sampler2D texY;\n"
        "uniform sampler2D texU;\n"
        "uniform sampler2D texV;\n"
        "void main(){\n"
        "  vec2 uv=gl_TexCoord[0].st;\n"
        "  float y=1.16438356*(texture2D(texY,uv).r-0.06274510);\n"
        "  float u=texture2D(texU,uv).r-0.5;\n"
        "  float v=texture2D(texV,uv).r-0.5;\n"
        "  vec3 rgb=vec3(y+1.79274107*v,\n"
        "                y-0.21324861*u-0.53290933*v,\n"
        "                y+2.11240179*u);\n"
        "  gl_FragColor=vec4(clamp(rgb,0.0,1.0),1.0);\n"
        "}\n";

    GLuint vs=CompileShader(GL_VERTEX_SHADER,vertex_source);
    GLuint fs=CompileShader(GL_FRAGMENT_SHADER,fragment_source);
    if(!vs||!fs){
        if(vs) glDeleteShader(vs);
        if(fs) glDeleteShader(fs);
        return false;
    }

    gl_yuv_program=glCreateProgram();
    glAttachShader(gl_yuv_program,vs);
    glAttachShader(gl_yuv_program,fs);
    glLinkProgram(gl_yuv_program);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint ok=0;
    glGetProgramiv(gl_yuv_program,GL_LINK_STATUS,&ok);
    if(!ok){
        char log[2048]{};
        GLsizei n=0;
        glGetProgramInfoLog(gl_yuv_program,sizeof(log)-1,&n,log);
        Log(std::string("OpenGL shader link failed: ")+log);
        glDeleteProgram(gl_yuv_program);
        gl_yuv_program=0;
        return false;
    }

    glUseProgram(gl_yuv_program);
    glUniform1i(glGetUniformLocation(gl_yuv_program,"texY"),0);
    glUniform1i(glGetUniformLocation(gl_yuv_program,"texU"),1);
    glUniform1i(glGetUniformLocation(gl_yuv_program,"texV"),2);
    glUseProgram(0);
    return true;
}

static void CopyPlane(std::vector<uint8_t>& dst,const uint8_t* src,int stride,int w,int h){
    dst.resize((size_t)w*(size_t)h);
    if(!src || w<=0 || h<=0) return;
    if(stride==w){
        memcpy(dst.data(),src,dst.size());
        return;
    }
    for(int row=0;row<h;++row)
        memcpy(dst.data()+(size_t)row*(size_t)w,src+(ptrdiff_t)row*stride,(size_t)w);
}

struct Decoder {
    AVCodecContext* ctx=nullptr;
    AVCodecParserContext* parser=nullptr;
    AVFrame *frame=nullptr,*sw=nullptr,*cached=nullptr;
    AVPacket* pkt=nullptr;
    SwsContext* sws=nullptr;
    bool hw=false;
    std::vector<uint32_t> prev_samples;

    bool Init(){
        const AVCodec* codec=avcodec_find_decoder(AV_CODEC_ID_H264);
        if(!codec) return false;
        ctx=avcodec_alloc_context3(codec);
        parser=av_parser_init(AV_CODEC_ID_H264);
        frame=av_frame_alloc(); sw=av_frame_alloc(); cached=av_frame_alloc(); pkt=av_packet_alloc();
        if(!ctx||!parser||!frame||!sw||!cached||!pkt) return false;
        const char* disable_vaapi=getenv("PADDISPLAY_DISABLE_VAAPI");
        bool allow_hw=!(disable_vaapi && std::string(disable_vaapi)!="0");
        if(!allow_hw) Log("decoder: VA-API disabled by PADDISPLAY_DISABLE_VAAPI");
        for(int i=0;allow_hw;++i){
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
        ctx->thread_count=hw?1:0;
        ctx->flags|=AV_CODEC_FLAG_LOW_DELAY;
        return avcodec_open2(ctx,codec,nullptr)>=0;
    }
    ~Decoder(){
        if(sws) sws_freeContext(sws);
        av_packet_free(&pkt); av_frame_free(&cached); av_frame_free(&sw); av_frame_free(&frame);
        if(parser) av_parser_close(parser);
        avcodec_free_context(&ctx);
    }
    bool Reset(){
        AVCodecParserContext* fresh=av_parser_init(AV_CODEC_ID_H264);
        if(!fresh) return false;
        av_parser_close(parser); parser=fresh;
        avcodec_flush_buffers(ctx);
        prev_samples.clear();
        std::lock_guard<std::mutex> lock(pending_frame_mtx);
        pending_frame=PendingVideoFrame{};
        return true;
    }
    void Present(AVFrame* src){
        ++decoded_frames;
        AVFrame* use=src;
        if(src->format==hw_fmt){
            av_frame_unref(sw);
            if(av_hwframe_map(sw,src,AV_HWFRAME_MAP_READ|AV_HWFRAME_MAP_DIRECT)<0){
                av_frame_unref(sw);
                if(av_hwframe_transfer_data(sw,src,0)<0){
                    Log("VA-API readback failed; use software decoding on this driver");
                    return;
                }
            } else {
                // Direct VA mappings are uncached; use FFmpeg's optimized GPU-memory copy.
                if(cached->format!=sw->format || cached->width!=sw->width || cached->height!=sw->height){
                    av_frame_unref(cached);
                    cached->format=sw->format; cached->width=sw->width; cached->height=sw->height;
                    if(av_frame_get_buffer(cached,64)<0) return;
                }
                if(av_frame_make_writable(cached)<0) return;
                ptrdiff_t dst_stride[4],src_stride[4];
                const uint8_t* source[4];
                for(int i=0;i<4;++i){
                    dst_stride[i]=cached->linesize[i]; src_stride[i]=sw->linesize[i]; source[i]=sw->data[i];
                }
                av_image_copy_uc_from(cached->data,dst_stride,source,src_stride,
                                      (AVPixelFormat)sw->format,sw->width,sw->height);
                use=cached;
            }
            if(use==src) use=sw;
        }

        const int w=use->width, h=use->height;
        if(w<=0 || h<=0) return;

        AVFrame* yuv=use;
        AVFrame* converted=nullptr;
        SwsContext* local_sws=nullptr;

        const AVPixelFormat fmt=(AVPixelFormat)use->format;
        if(fmt!=AV_PIX_FMT_YUV420P && fmt!=AV_PIX_FMT_YUVJ420P){
            converted=av_frame_alloc();
            if(!converted) return;
            converted->format=AV_PIX_FMT_YUV420P;
            converted->width=w;
            converted->height=h;
            if(av_frame_get_buffer(converted,32)<0){
                av_frame_free(&converted);
                return;
            }
            local_sws=sws_getContext(w,h,fmt,w,h,AV_PIX_FMT_YUV420P,
                                     SWS_FAST_BILINEAR,nullptr,nullptr,nullptr);
            if(!local_sws ||
               sws_scale(local_sws,use->data,use->linesize,0,h,
                         converted->data,converted->linesize)<=0){
                if(local_sws) sws_freeContext(local_sws);
                av_frame_free(&converted);
                return;
            }
            yuv=converted;
        }

        const int cw=(w+1)/2;
        const int ch=(h+1)/2;
        PendingVideoFrame out;
        out.w=w;
        out.h=h;
        CopyPlane(out.y,yuv->data[0],yuv->linesize[0],w,h);
        CopyPlane(out.u,yuv->data[1],yuv->linesize[1],cw,ch);
        CopyPlane(out.v,yuv->data[2],yuv->linesize[2],cw,ch);

        if(local_sws) sws_freeContext(local_sws);
        if(converted) av_frame_free(&converted);

        // Lightweight luma-only diagnostics. Avoid the former RGB conversion
        // and sampling cost in the hot path.
        uint64_t hash=1469598103934665603ULL;
        constexpr size_t sample_count=4096;
        std::vector<uint32_t> samples;
        samples.reserve(sample_count);
        uint64_t changed=0;
        const size_t pixels=out.y.size();
        for(size_t n=0;n<sample_count && pixels;++n){
            size_t i=((uint64_t)n*(uint64_t)pixels)/sample_count;
            if(i>=pixels) i=pixels-1;
            uint32_t value=out.y[i];
            samples.push_back(value);
            hash^=value;
            hash*=1099511628211ULL;
            if(prev_samples.size()==sample_count &&
               std::abs(int(value)-int(prev_samples[n]))>6) ++changed;
        }
        frame_fingerprint=hash;
        frame_change_ppm=prev_samples.size()==sample_count ?
            (changed*1000000ULL/sample_count) : 0;
        prev_samples=std::move(samples);

        {
            std::lock_guard<std::mutex> lock(pending_frame_mtx);
            pending_frame=std::move(out);
            pending_frame.ready=true;
        }
    }
    void Feed(const uint8_t* data,size_t bytes){
        while(bytes){
            uint8_t* out=nullptr; int out_n=0;
            int used=av_parser_parse2(parser,ctx,&out,&out_n,data,(int)bytes,AV_NOPTS_VALUE,AV_NOPTS_VALUE,0);
            if(used<0 || (used==0 && out_n==0)) return;
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
        if(chunk.empty()){
            if(!d.Reset()){Log("decoder reset failed");running=false;video_cv.notify_all();return;}
            continue;
        }
        const size_t bytes=chunk.size();
        // FFmpeg bitstream readers require zero padding beyond the input.
        chunk.resize(bytes+AV_INPUT_BUFFER_PADDING_SIZE,0);
        d.Feed(chunk.data(),bytes);
    }
}
static void ResetAudioPlayback(){
    if(audio_dev){
        SDL_PauseAudioDevice(audio_dev,1);
        SDL_ClearQueuedAudio(audio_dev);
    }
    if(audio_stream) SDL_AudioStreamClear(audio_stream);
    audio_playing=false;
}

static SDL_AudioFormat AudioFormatFromWire(uint8_t code){
    switch(code){
        case 1: return AUDIO_S16LSB;
        case 3: return AUDIO_S32LSB;
        case 4: return AUDIO_F32LSB;
        default: return 0;
    }
}

static void QueuePCM(const uint8_t* out_data,int out_bytes){
    Uint32 queued=SDL_GetQueuedAudioSize(audio_dev);
    if(audio_playing && queued==0){
        SDL_PauseAudioDevice(audio_dev,1);
        audio_playing=false;
        ++audio_underruns;
    }
    if(queued+(uint64_t)out_bytes>AUDIO_MAX){
        SDL_PauseAudioDevice(audio_dev,1);
        SDL_ClearQueuedAudio(audio_dev);
        audio_playing=false;
        ++audio_underruns;
        ++audio_overflows;
        queued=0;
    }

    if((size_t)out_bytes>AUDIO_MAX){
        out_data+=out_bytes-AUDIO_MAX;
        out_bytes=(int)AUDIO_MAX;
    }
    if(SDL_QueueAudio(audio_dev,out_data,(Uint32)out_bytes)!=0){
        Log(std::string("SDL_QueueAudio failed: ")+SDL_GetError());
        return;
    }

    ++audio_packets;
    queued=SDL_GetQueuedAudioSize(audio_dev);
    if(!audio_playing.load() && queued>=AUDIO_START_BYTES){
        SDL_PauseAudioDevice(audio_dev,0);
        audio_playing=true;
    }
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

        ResetAudioPlayback();
        if(audio_stream){ SDL_FreeAudioStream(audio_stream); audio_stream=nullptr; }
        bool audio_direct=true;
        uint16_t source_align=4;
        Log("audio connected");

        while(running){
            uint8_t h[5];
            if(!ReadExact(fd,h,5)) break;
            uint32_t n=(uint32_t(h[0])<<24)|(uint32_t(h[1])<<16)|(uint32_t(h[2])<<8)|h[3];
            if(n>4*1024*1024) break;
            std::vector<uint8_t> p(n);
            if(n&&!ReadExact(fd,p.data(),n)) break;

            if(h[4]==DISCONNECT) break;
            if(h[4]==AUDIO_FORMAT){
                if(n!=8){
                    Log("audio format packet invalid length");
                    continue;
                }
                uint32_t rate=(uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|p[3];
                uint8_t channels=p[4];
                uint8_t format_code=p[5];
                uint16_t block_align=(uint16_t(p[6])<<8)|p[7];
                SDL_AudioFormat src_format=AudioFormatFromWire(format_code);
                if(!src_format || rate<8000 || rate>384000 || channels==0 || channels>32 ||
                   block_align!=channels*(SDL_AUDIO_BITSIZE(src_format)/8)){
                    Log("audio format packet unsupported");
                    continue;
                }

                ResetAudioPlayback();
                if(audio_stream){ SDL_FreeAudioStream(audio_stream); audio_stream=nullptr; }
                source_align=block_align;
                audio_direct=(src_format==AUDIO_S16LSB && channels==2 && rate==48000 && block_align==4);
                if(!audio_direct){
                    audio_stream=SDL_NewAudioStream(
                        src_format, channels, (int)rate,
                        AUDIO_S16LSB, 2, 48000
                    );
                    if(!audio_stream){
                        Log(std::string("SDL_NewAudioStream failed: ")+SDL_GetError());
                        continue;
                    }
                }
                Log("audio source: rate="+std::to_string(rate)+
                    " channels="+std::to_string((unsigned)channels)+
                    " format_code="+std::to_string((unsigned)format_code)+
                    " block_align="+std::to_string(block_align)+
                    (audio_direct ? " direct s16 playback" : " -> SDL conversion"));
                continue;
            }

            size_t off=0;
            if(h[4]==AUDIO_PCM_V2 && n>=12) off=12;
            else if(h[4]==AUDIO_PCM) off=0;
            else continue;

            size_t usable=p.size()-off;
            if(!usable || usable%source_align || !audio_dev || (!audio_direct && !audio_stream)) continue;

            std::vector<uint8_t> converted;
            const uint8_t* out_data=nullptr;
            int out_bytes=0;

            if(audio_direct){
                usable-=usable%4;
                if(!usable) continue;
                out_data=p.data()+off;
                out_bytes=(int)usable;
            } else {
                if(SDL_AudioStreamPut(audio_stream,p.data()+off,(int)usable)!=0){
                    Log(std::string("SDL_AudioStreamPut failed: ")+SDL_GetError());
                    continue;
                }

                int available=SDL_AudioStreamAvailable(audio_stream);
                if(available<0){
                    Log(std::string("SDL_AudioStreamAvailable failed: ")+SDL_GetError());
                    continue;
                }
                if(available<=0) continue;

                converted.resize((size_t)available);
                int got=SDL_AudioStreamGet(audio_stream,converted.data(),available);
                if(got<0){
                    Log(std::string("SDL_AudioStreamGet failed: ")+SDL_GetError());
                    continue;
                }
                if(got<=0) continue;
                out_data=converted.data();
                out_bytes=got;
            }

            QueuePCM(out_data,out_bytes);
        }

        ResetAudioPlayback();
        if(audio_stream){ SDL_FreeAudioStream(audio_stream); audio_stream=nullptr; }
        close(fd);
        Log("audio disconnected");
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
        {
            std::lock_guard<std::mutex> lock(video_mtx);
            video_q.clear();
            video_q.emplace_back(); // Empty entry resets the decoder before the new stream.
        }
        video_cv.notify_all();
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
            if(h[4]==VIDEO_H264 && n){
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
static void SetX11FullscreenHint(bool enable){
    if(!window_) return;

    SDL_SysWMinfo info{};
    SDL_VERSION(&info.version);
    if(!SDL_GetWindowWMInfo(window_,&info)) {
        Log(std::string("fullscreen: SDL_GetWindowWMInfo failed: ")+SDL_GetError());
        return;
    }
    if(info.subsystem!=SDL_SYSWM_X11) return;

    Display* display=info.info.x11.display;
    Window xwindow=info.info.x11.window;
    Window root=DefaultRootWindow(display);

    Atom wm_state=XInternAtom(display,"_NET_WM_STATE",False);
    Atom fullscreen=XInternAtom(display,"_NET_WM_STATE_FULLSCREEN",False);

    XEvent event{};
    event.xclient.type=ClientMessage;
    event.xclient.window=xwindow;
    event.xclient.message_type=wm_state;
    event.xclient.format=32;
    event.xclient.data.l[0]=enable ? 1 : 0; // _NET_WM_STATE_ADD / REMOVE
    event.xclient.data.l[1]=fullscreen;
    event.xclient.data.l[2]=0;
    event.xclient.data.l[3]=1; // source indication: normal application
    event.xclient.data.l[4]=0;

    XSendEvent(display,root,False,
               SubstructureRedirectMask|SubstructureNotifyMask,&event);
    XFlush(display);
}

static void SetBorderlessFullscreen(bool enable){
    if(!window_) return;

    if(enable){
        SDL_GetWindowPosition(window_,&windowed_x,&windowed_y);
        SDL_GetWindowSize(window_,&windowed_w,&windowed_h);

        int display=SDL_GetWindowDisplayIndex(window_);
        SDL_Rect bounds{};
        if(display<0 || SDL_GetDisplayBounds(display,&bounds)!=0){
            Log(std::string("fullscreen: failed to get display bounds: ")+SDL_GetError());
            return;
        }

        SDL_SetWindowBordered(window_,SDL_FALSE);
        SDL_SetWindowAlwaysOnTop(window_,SDL_TRUE);
        SetX11FullscreenHint(true);
        SDL_SetWindowPosition(window_,bounds.x,bounds.y);
        SDL_SetWindowSize(window_,bounds.w,bounds.h);
        SDL_RaiseWindow(window_);
        fullscreen_=true;
        Log("fullscreen: borderless "+std::to_string(bounds.w)+"x"+std::to_string(bounds.h));
    } else {
        SetX11FullscreenHint(false);
        SDL_SetWindowAlwaysOnTop(window_,SDL_FALSE);
        SDL_SetWindowBordered(window_,SDL_TRUE);
        SDL_SetWindowSize(window_,windowed_w,windowed_h);
        SDL_SetWindowPosition(window_,windowed_x,windowed_y);
        SDL_RaiseWindow(window_);
        fullscreen_=false;
        Log("fullscreen: restored window "+std::to_string(windowed_w)+"x"+std::to_string(windowed_h));
    }
}

static uint16_t Norm(int v,int maxv){
    if(maxv<=1) return 0; v=std::max(0,std::min(v,maxv-1));
    return (uint16_t)((uint64_t)v*65535/(uint64_t)(maxv-1));
}
static void SendMouse(uint8_t action,uint8_t button,int x,int y,int wheel){
    int w=1,h=1;
    SDL_GetWindowSize(window_,&w,&h);

    int content_x=0,content_y=0,content_w=w,content_h=h;
    if(stream_w>0 && stream_h>0 && w>0 && h>0){
        const double src_aspect=(double)stream_w/(double)stream_h;
        const double dst_aspect=(double)w/(double)h;
        if(dst_aspect>src_aspect){
            content_w=std::max(1,(int)std::lround((double)h*src_aspect));
            content_x=(w-content_w)/2;
        } else if(dst_aspect<src_aspect){
            content_h=std::max(1,(int)std::lround((double)w/src_aspect));
            content_y=(h-content_h)/2;
        }
    }

    int mapped_x=std::max(0,std::min(content_w-1,x-content_x));
    int mapped_y=std::max(0,std::min(content_h-1,y-content_y));
    uint16_t nx=Norm(mapped_x,content_w),ny=Norm(mapped_y,content_h);

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
        case SDLK_LSHIFT:return 0xA0; case SDLK_RSHIFT:return 0xA1;
        case SDLK_LCTRL:return 0xA2; case SDLK_RCTRL:return 0xA3;
        case SDLK_LALT:return 0xA4; case SDLK_RALT:return 0xA5;
        case SDLK_LGUI:return 0x5B; case SDLK_RGUI:return 0x5C;
        case SDLK_INSERT:return 0x2D; case SDLK_CAPSLOCK:return 0x14;
        case SDLK_NUMLOCKCLEAR:return 0x90; case SDLK_SCROLLLOCK:return 0x91;
        case SDLK_PRINTSCREEN:return 0x2C; case SDLK_PAUSE:return 0x13;
        case SDLK_SEMICOLON:return 0xBA; case SDLK_EQUALS:return 0xBB;
        case SDLK_COMMA:return 0xBC; case SDLK_MINUS:return 0xBD;
        case SDLK_PERIOD:return 0xBE; case SDLK_SLASH:return 0xBF;
        case SDLK_BACKQUOTE:return 0xC0; case SDLK_LEFTBRACKET:return 0xDB;
        case SDLK_BACKSLASH:return 0xDC; case SDLK_RIGHTBRACKET:return 0xDD;
        case SDLK_QUOTE:return 0xDE;
        case SDLK_KP_0:return 0x60; case SDLK_KP_1:return 0x61; case SDLK_KP_2:return 0x62;
        case SDLK_KP_3:return 0x63; case SDLK_KP_4:return 0x64; case SDLK_KP_5:return 0x65;
        case SDLK_KP_6:return 0x66; case SDLK_KP_7:return 0x67; case SDLK_KP_8:return 0x68;
        case SDLK_KP_9:return 0x69; case SDLK_KP_MULTIPLY:return 0x6A;
        case SDLK_KP_PLUS:return 0x6B; case SDLK_KP_MINUS:return 0x6D;
        case SDLK_KP_PERIOD:return 0x6E; case SDLK_KP_DIVIDE:return 0x6F;
        case SDLK_KP_ENTER:return 0x0D;
        case SDLK_F1:return 0x70;case SDLK_F2:return 0x71;case SDLK_F3:return 0x72;case SDLK_F4:return 0x73;
        case SDLK_F5:return 0x74;case SDLK_F6:return 0x75;case SDLK_F7:return 0x76;case SDLK_F8:return 0x77;
        case SDLK_F9:return 0x78;case SDLK_F10:return 0x79;case SDLK_F11:return 0x7A;case SDLK_F12:return 0x7B;
        default:return 0;
    }
}
static void SendKey(const SDL_KeyboardEvent& e,bool up){
    uint16_t vk=WinVk(e.keysym.sym); if(!vk) return;
    // SDL scancodes are USB usages, not Windows scan codes; use the VK fallback.
    const SDL_Keycode key=e.keysym.sym;
    uint8_t extended=key==SDLK_RCTRL || key==SDLK_RALT || key==SDLK_LGUI ||
        key==SDLK_RGUI || key==SDLK_LEFT || key==SDLK_RIGHT || key==SDLK_UP ||
        key==SDLK_DOWN || key==SDLK_HOME || key==SDLK_END || key==SDLK_PAGEUP ||
        key==SDLK_PAGEDOWN || key==SDLK_INSERT || key==SDLK_DELETE ||
        key==SDLK_KP_ENTER || key==SDLK_KP_DIVIDE;
    uint8_t p[6]={uint8_t(up?1:0),uint8_t(vk>>8),uint8_t(vk),0,0,extended};
    SendPacket(KEYBOARD_V1,p,sizeof(p));
}

static void SetupYuvTexture(GLuint texture,int unit,int w,int h,const uint8_t* pixels,bool allocate){
    glActiveTexture(GL_TEXTURE0+unit);
    glBindTexture(GL_TEXTURE_2D,texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    if(allocate)
        glTexImage2D(GL_TEXTURE_2D,0,GL_LUMINANCE,w,h,0,GL_LUMINANCE,GL_UNSIGNED_BYTE,pixels);
    else
        glTexSubImage2D(GL_TEXTURE_2D,0,0,0,w,h,GL_LUMINANCE,GL_UNSIGNED_BYTE,pixels);
}

static bool RenderPendingFrame(){
    PendingVideoFrame frame;
    {
        std::lock_guard<std::mutex> lock(pending_frame_mtx);
        if(!pending_frame.ready) return false;
        frame=std::move(pending_frame);
        pending_frame=PendingVideoFrame{};
    }

    if(frame.w<=0 || frame.h<=0 || frame.y.empty() || frame.u.empty() || frame.v.empty() ||
       !window_ || !gl_context || !gl_yuv_program) return false;

    if(!gl_yuv_textures[0]) glGenTextures(3,gl_yuv_textures);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);

    const int cw=(frame.w+1)/2;
    const int ch=(frame.h+1)/2;
    const bool allocate=(frame.w!=gl_tex_w || frame.h!=gl_tex_h);

    SetupYuvTexture(gl_yuv_textures[0],0,frame.w,frame.h,frame.y.data(),allocate);
    SetupYuvTexture(gl_yuv_textures[1],1,cw,ch,frame.u.data(),allocate);
    SetupYuvTexture(gl_yuv_textures[2],2,cw,ch,frame.v.data(),allocate);

    if(allocate){
        gl_tex_w=frame.w;
        gl_tex_h=frame.h;
        stream_w=frame.w;
        stream_h=frame.h;
        Log("video mode: "+std::to_string(stream_w)+"x"+std::to_string(stream_h)+" OpenGL YUV420");
    }

    int dw=1,dh=1;
    SDL_GL_GetDrawableSize(window_,&dw,&dh);
    glViewport(0,0,dw,dh);
    glClearColor(0.f,0.f,0.f,1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    const float src_aspect=(float)frame.w/(float)frame.h;
    const float dst_aspect=(float)dw/(float)dh;
    float sx=1.f,sy=1.f;
    if(dst_aspect>src_aspect) sx=src_aspect/dst_aspect;
    else sy=dst_aspect/src_aspect;

    glUseProgram(gl_yuv_program);
    glBegin(GL_QUADS);
      glMultiTexCoord2f(GL_TEXTURE0,0.f,0.f); glVertex2f(-sx, sy);
      glMultiTexCoord2f(GL_TEXTURE0,1.f,0.f); glVertex2f( sx, sy);
      glMultiTexCoord2f(GL_TEXTURE0,1.f,1.f); glVertex2f( sx,-sy);
      glMultiTexCoord2f(GL_TEXTURE0,0.f,1.f); glVertex2f(-sx,-sy);
    glEnd();
    glUseProgram(0);

    SDL_GL_SwapWindow(window_);
    ++frames;
    return true;
}

static void DrawStatus(const char* message){
    (void)message;
    if(!window_ || !gl_context) return;
    int dw=1,dh=1;
    SDL_GL_GetDrawableSize(window_,&dw,&dh);
    glViewport(0,0,dw,dh);
    glUseProgram(0);
    glClearColor(0.07f,0.07f,0.09f,1.f);
    glClear(GL_COLOR_BUFFER_BIT);
    SDL_GL_SwapWindow(window_);
}

int main(){
    const char* home=getenv("HOME");
    std::string state=home?std::string(home)+"/.local/state/paddisplay":"/tmp/paddisplay";
    if(home){mkdir((std::string(home)+"/.local").c_str(),0755);mkdir((std::string(home)+"/.local/state").c_str(),0755);}
    mkdir(state.c_str(),0755); log_file.open(state+"/receiver.log",std::ios::app);
    if(SDL_Init(SDL_INIT_VIDEO|SDL_INIT_AUDIO|SDL_INIT_EVENTS)!=0){fprintf(stderr,"SDL init failed: %s\n",SDL_GetError());return 1;}
    if(TTF_Init()!=0) Log(std::string("SDL_ttf init failed: ")+TTF_GetError());
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION,2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION,1);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER,1);
    window_=SDL_CreateWindow("PadDisplay Linux Client",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,1366,768,
                             SDL_WINDOW_SHOWN|SDL_WINDOW_RESIZABLE|SDL_WINDOW_OPENGL);
    if(!window_){fprintf(stderr,"SDL window failed: %s\n",SDL_GetError());return 1;}
    gl_context=SDL_GL_CreateContext(window_);
    if(!gl_context){fprintf(stderr,"OpenGL context failed: %s\n",SDL_GetError());return 1;}
    if(SDL_GL_MakeCurrent(window_,gl_context)!=0){fprintf(stderr,"OpenGL make-current failed: %s\n",SDL_GetError());return 1;}
    // Prefer adaptive vsync: synchronize swaps to the display refresh to
    // eliminate tearing, but allow a late frame to swap immediately when the
    // driver supports EXT_swap_control_tear. Fall back to ordinary vsync.
    int swap_interval=0;
    if(SDL_GL_SetSwapInterval(-1)==0){
        swap_interval=-1;
        Log("OpenGL swap interval: adaptive vsync");
    } else if(SDL_GL_SetSwapInterval(1)==0){
        swap_interval=1;
        Log("OpenGL swap interval: vsync");
    } else {
        SDL_GL_SetSwapInterval(0);
        Log(std::string("OpenGL swap interval: unsynchronized (vsync unavailable): ")+SDL_GetError());
    }
    (void)swap_interval;
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    if(!InitYuvShader()){
        fprintf(stderr,"OpenGL YUV shader initialization failed; see receiver log.\n");
        return 1;
    }
    const char* video_driver=SDL_GetCurrentVideoDriver();
    Log(std::string("SDL video driver: ")+(video_driver?video_driver:"unknown"));
    Log(std::string("SDL presentation: OpenGL ")+
        reinterpret_cast<const char*>(glGetString(GL_VERSION)));
    status_font=TTF_OpenFont("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",36);
    if(!status_font) Log(std::string("status font unavailable: ")+TTF_GetError());
    SDL_SetWindowTitle(window_,"PadDisplay - Waiting for host...");
    DrawStatus("PadDisplay - Waiting for host...");
    SDL_AudioSpec want{},got{};
    want.freq=48000;
    want.format=AUDIO_S16LSB;
    want.channels=2;
    want.samples=512;
    want.callback=nullptr;
    audio_dev=SDL_OpenAudioDevice(nullptr,0,&want,&got,0);
    if(audio_dev){
        SDL_PauseAudioDevice(audio_dev,1);
        Log("audio device: freq="+std::to_string(got.freq)+
            " format="+std::to_string((unsigned)got.format)+
            " channels="+std::to_string((unsigned)got.channels)+
            " samples="+std::to_string(got.samples));
    } else {
        Log(std::string("audio open failed: ")+SDL_GetError());
    }
    std::thread aud(AudioThread),net(NetworkThread),dec(DecodeThread),discovery(DiscoveryThread);
    auto last=std::chrono::steady_clock::now();
    uint64_t last_decoded=0, last_presented=0;
    bool last_connected=false;
    while(running){
        SDL_Event e{};
        bool have_motion=false;
        int motion_x=0,motion_y=0;
        while(SDL_PollEvent(&e)){
            if(e.type==SDL_QUIT) running=false;
            else if(e.type==SDL_KEYDOWN||e.type==SDL_KEYUP){
                bool up=e.type==SDL_KEYUP; SDL_Keymod mods=SDL_GetModState();

                // F11 is a local receiver shortcut: consume both keydown and
                // keyup so Windows never sees half of a key sequence.
                if(e.key.keysym.sym==SDLK_F11){
                    if(!up && e.key.repeat==0) SetBorderlessFullscreen(!fullscreen_);
                } else if(!up&&e.key.keysym.sym==SDLK_q&&(mods&KMOD_CTRL)&&(mods&KMOD_SHIFT)){
                    running=false;
                } else if(e.key.keysym.sym==SDLK_ESCAPE&&fullscreen_){
                    if(!up && e.key.repeat==0) SetBorderlessFullscreen(false);
                } else {
                    SendKey(e.key,up);
                }
            } else if(e.type==SDL_MOUSEMOTION){
                // Coalesce motion bursts and send only the newest absolute
                // position once per render loop. Buttons/wheel remain immediate.
                have_motion=true;
                motion_x=e.motion.x;
                motion_y=e.motion.y;
            } else if(e.type==SDL_MOUSEBUTTONDOWN||e.type==SDL_MOUSEBUTTONUP){
                uint8_t b=e.button.button==SDL_BUTTON_LEFT?1:e.button.button==SDL_BUTTON_RIGHT?2:e.button.button==SDL_BUTTON_MIDDLE?3:0;
                if(b) SendMouse(e.type==SDL_MOUSEBUTTONDOWN?1:2,b,e.button.x,e.button.y,0);
            } else if(e.type==SDL_MOUSEWHEEL){
                int x=0,y=0;SDL_GetMouseState(&x,&y);SendMouse(3,0,x,y,e.wheel.y*120);
            }
        }
        if(have_motion) SendMouse(0,0,motion_x,motion_y,0);
        bool now_connected=connected.load();
        if(now_connected!=last_connected){
            last_connected=now_connected;
            if(now_connected){
                SDL_SetWindowTitle(window_,"PadDisplay - Connected");
            } else {
                SDL_SetWindowTitle(window_,"PadDisplay - Waiting for host...");
                DrawStatus("PadDisplay - Waiting for host...");
            }
        }

        bool presented=false;
        if(now_connected) presented=RenderPendingFrame();
        if(!presented) SDL_Delay(1);

        auto now=std::chrono::steady_clock::now();
        if(now-last>=std::chrono::seconds(5)){
            const double elapsed=std::chrono::duration<double>(now-last).count();
            const uint64_t decoded_now=decoded_frames.load();
            const uint64_t presented_now=frames.load();
            size_t video_q_depth=0;
            {
                std::lock_guard<std::mutex> lock(video_mtx);
                video_q_depth=video_q.size();
            }
            const double decode_fps=(decoded_now-last_decoded)/elapsed;
            const double present_fps=(presented_now-last_presented)/elapsed;
            Log("health connected="+std::to_string(connected.load())+
                " video_packets="+std::to_string(video_packets.load())+
                " video_bytes="+std::to_string(video_bytes.load())+
                " decoded_frames="+std::to_string(decoded_now)+
                " frames="+std::to_string(presented_now)+
                " decode_fps="+std::to_string(decode_fps)+
                " present_fps="+std::to_string(present_fps)+
                " video_q="+std::to_string(video_q_depth)+
                " frame_hash="+std::to_string(frame_fingerprint.load())+
                " frame_change_ppm="+std::to_string(frame_change_ppm.load())+
                " audio_packets="+std::to_string(audio_packets.load())+
                " audio_queued="+std::to_string(audio_dev?SDL_GetQueuedAudioSize(audio_dev):0)+
                " audio_resets="+std::to_string(audio_underruns.load())+
                " audio_overflows="+std::to_string(audio_overflows.load()));
            last_decoded=decoded_now;
            last_presented=presented_now;
            last=now;
        }
    }
    if(client_fd>=0) shutdown(client_fd,SHUT_RDWR);
    video_cv.notify_all();
    net.join(); dec.join(); aud.join(); discovery.join();
    if(audio_stream){ SDL_FreeAudioStream(audio_stream); audio_stream=nullptr; }
    if(audio_dev) SDL_CloseAudioDevice(audio_dev);
    if(gl_yuv_textures[0]) glDeleteTextures(3,gl_yuv_textures);
    if(gl_yuv_program) glDeleteProgram(gl_yuv_program);
    if(gl_context){ SDL_GL_DeleteContext(gl_context); gl_context=nullptr; }
    if(status_font) TTF_CloseFont(status_font);
    if(window_) SDL_DestroyWindow(window_);
    if(hw_device) av_buffer_unref(&hw_device);
    TTF_Quit();
    SDL_Quit();
    return 0;
}
