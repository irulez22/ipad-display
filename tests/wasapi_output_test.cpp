#define wmain PadDisplayWasapiMain
#include "../tools/wasapi_loopback.cpp"
#undef wmain

int main() {
    if (!prepare_pcm_output()) return 1;
    uint8_t bytes[256];
    for (int i=0;i<256;i++) bytes[i]=(uint8_t)i;
    return fwrite(bytes,1,sizeof(bytes),stdout)==sizeof(bytes) ? 0 : 1;
}
