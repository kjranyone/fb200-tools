#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "dsp/drums.h"
#include "dsp/tuner.h"

/* cab.h needs CMSIS; the standalone declaration lives in cab_rate.c. */
void cab_ir_441_to_48(float *ir, unsigned taps);

static unsigned services;
void tuner_service(void) { services++; }

/* cab_ir_441_to_48 against an independent computation on a copy: the output
 * must equal linear interpolation of the 44.1 kHz taps at 48 kHz positions,
 * in place, truncating the shifted-out tail. */
static void check_cab_resample(void)
{
    enum { TAPS = 512 };
    static float ir[TAPS], ref[TAPS];
    for (unsigned i = 0; i < TAPS; i++)
        ref[i] = ir[i] = sinf(0.05f * i) * expf(-0.004f * i) + 0.1f * i;
    cab_ir_441_to_48(ir, TAPS);
    for (unsigned i = 0; i < TAPS; i++) {
        unsigned num = i * 44100u;
        unsigned idx = num / 48000u;
        float frac = (float)(num % 48000u) / 48000.0f;
        float expected = idx >= TAPS ? 0.0f
            : ref[idx] + (idx + 1u < TAPS ? ref[idx + 1u] - ref[idx] : -ref[idx]) * frac;
        /* a couple of ulps at the sample's magnitude */
        assert(fabsf(ir[i] - expected) <= 1e-5f + 1e-6f * fabsf(expected));
    }
    /* The direct (b = 0.0) tail guard: a buffer shorter than the read. */
    float one[1] = { 3.0f };
    cab_ir_441_to_48(one, 1);
    assert(one[0] == 3.0f);   /* i=0 reads itself, frac 0 */
}

static void pitch(float frequency)
{
    static tuner_t t;
    tuner_result_t r = {0};
    tuner_init(&t, 440);
    for (unsigned i=0; i<AUDIO_FS; i++) {
        float x = 0.3f*sinf(6.28318530718f*frequency*(float)i/(float)AUDIO_FS);
        tuner_feed(&t, &x, 1);
        (void)tuner_poll(&t, &r);
    }
    printf("rate %u input %.5f detected %.5f valid %d silent %d\n", AUDIO_FS,
           (double)frequency,(double)r.freq,r.valid,r.silent);
    fflush(stdout);
    assert(r.valid && fabsf(1200.0f*log2f(r.freq/frequency))<2.0f);
}

int main(void)
{
    check_cab_resample();
    pitch(41.20344f); pitch(110.0f); pitch(440.0f);
    assert(services>0);
    enum { SAMPLES=44100 };
    static uint32_t bank[128+SAMPLES];
    bank[0]=1; bank[2]=1; bank[3]=SAMPLES*4;
    float *samples=(float *)((uint8_t *)bank+512);
    for(unsigned i=0;i<SAMPLES;i++) samples[i]=(float)i/44100.0f;
    static const uint32_t ev[]={0x017f, (120u<<16)|0xff00};
    static uint16_t lens[90]; static uint8_t rhythms[40], beats[90];
    lens[0]=2; memset(beats,4,sizeof beats);
    drums_data_t data={ev,2,lens,90,rhythms,40,beats};
    static drums_t source, output;
    assert(!drums_init(&source,bank,&data)); assert(!drums_init(&output,bank,&data));
    assert(!drums_set_output_rate(&output,48000));
    assert(drums_set_output_rate(&output,96000)==-1);
    drums_start(&source); drums_start(&output);
    static float native[22052], got[24000];
    drums_render(&source,native,22052);
    drums_set_level(&output,100);
    drums_process(&output,got,24000);
    /* Compare to independent linear interpolation of the 44.1 kHz sequence.
     * This simultaneously checks sequencer tempo and sample playback pitch. */
    for(unsigned i=0;i<24000;i++) {
        unsigned numerator=i*44100u, index=numerator/48000u;
        float fraction=(float)(numerator%48000u)/48000.0f;
        float expected=native[index]+(native[index+1]-native[index])*fraction;
        assert(fabsf(got[i]-expected*100.0f*0.02f*0.8f)<1e-5f);
    }
    puts("manager rates OK");
    return 0;
}
