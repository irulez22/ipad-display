#define main PadDisplayMain
#include "../tools/linux-receiver/PadDisplayReceiverLinux.cpp"
#undef main
#include <cassert>
#include <iterator>

int main(){
    int sockets[2];
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);
    client_fd=sockets[0];
    struct KeyCase { SDL_Keycode key; uint16_t vk; uint8_t extended; };
    const KeyCase keys[]={
        {SDLK_a,0x41,0},{SDLK_SEMICOLON,0xBA,0},{SDLK_LEFT,0x25,1},
        {SDLK_RCTRL,0xA3,1},{SDLK_RSHIFT,0xA1,0},{SDLK_KP_ENTER,0x0D,1}
    };
    for(const auto& key:keys){
        SDL_KeyboardEvent e{};
        e.keysym.sym=key.key;
        e.keysym.scancode=SDL_SCANCODE_A; // Must never appear as a Windows scan code.
        for(bool up:{false,true}){
            SendKey(e,up);
            uint8_t packet[11]{};
            assert(ReadExact(sockets[1],packet,sizeof(packet)));
            assert(packet[3]==6 && packet[4]==KEYBOARD_V1);
            assert(packet[5]==(up?1:0));
            assert(packet[6]==(key.vk>>8) && packet[7]==(key.vk&255));
            assert(packet[8]==0 && packet[9]==0 && packet[10]==key.extended);
        }
    }
    client_fd=-1;
    close(sockets[0]); close(sockets[1]);

    SDL_setenv("SDL_AUDIODRIVER","dummy",1);
    assert(SDL_Init(SDL_INIT_AUDIO)==0);
    SDL_AudioSpec want{};
    want.freq=48000;want.format=AUDIO_S16LSB;want.channels=2;want.samples=512;
    audio_dev=SDL_OpenAudioDevice(nullptr,0,&want,nullptr,0);
    assert(audio_dev);
    std::vector<uint8_t> pcm(AUDIO_MAX*2,0);
    QueuePCM(pcm.data(),3840);
    assert(!audio_playing && SDL_GetQueuedAudioSize(audio_dev)==3840);
    QueuePCM(pcm.data(),3840);
    assert(audio_playing);
    SDL_PauseAudioDevice(audio_dev,1);
    SDL_ClearQueuedAudio(audio_dev);
    auto underruns=audio_underruns.load();
    QueuePCM(pcm.data(),3840);
    assert(!audio_playing && audio_underruns==underruns+1);
    QueuePCM(pcm.data(),(int)pcm.size());
    assert(SDL_GetQueuedAudioSize(audio_dev)<=AUDIO_MAX);
    ResetAudioPlayback();
    assert(SDL_GetQueuedAudioSize(audio_dev)==0 && !audio_playing);
    SDL_CloseAudioDevice(audio_dev);audio_dev=0;
    SDL_Quit();

    setenv("PADDISPLAY_DISABLE_VAAPI","1",1);
    std::ifstream fixture("test.h264",std::ios::binary);
    assert(fixture);
    std::vector<uint8_t> data(1024*1024);
    fixture.read(reinterpret_cast<char*>(data.data()),data.size());
    data.resize((size_t)fixture.gcount());
    assert(!data.empty());
    Decoder decoder;
    assert(decoder.Init());
    for(int session=0;session<2;session++){
        auto before=decoded_frames.load();
        for(size_t pos=0;pos<data.size();pos+=16384){
            size_t n=std::min<size_t>(16384,data.size()-pos);
            std::vector<uint8_t> chunk(n+AV_INPUT_BUFFER_PADDING_SIZE,0);
            memcpy(chunk.data(),data.data()+pos,n);
            decoder.Feed(chunk.data(),n);
        }
        assert(decoded_frames>before);
        assert(pending_frame.ready);
        assert(decoder.Reset());
        assert(!pending_frame.ready);
    }
    puts("Linux keyboard, audio buffering, and decoder reconnect checks passed");
}
