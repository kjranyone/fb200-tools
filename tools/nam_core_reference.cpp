// Optional host oracle; compile against the pinned Core in docs/NAM_A2_LITE.md.
// Reads a validated bare WaveNet .nam and mono float32 input, writes float32 output.
#include <algorithm>
#include <fstream>
#include <stdexcept>
#include <vector>
#include "NAM/dsp.h"
#include "NAM/wavenet/a2_fast.h"

int main(int argc, char** argv)
{
    if (argc != 4) return 2;
    nlohmann::json model;
    std::ifstream file(argv[1]);
    file >> model;
    const auto config = model.at("config");
    int channels = 0;
    if (!nam::wavenet::a2_fast::is_a2_shape(config, &channels) || channels != 3)
        throw std::runtime_error("not fixed A2-Lite");
    auto dsp = nam::wavenet::a2_fast::create_a2_fast_config(config, 48000)->create(
        model.at("weights").get<std::vector<float>>(), 48000);
    dsp->SetPrewarmOnReset(false); // compare the same zero-state initial condition
    dsp->Reset(48000, 32);
    std::ifstream input(argv[2], std::ios::binary);
    std::ofstream output(argv[3], std::ios::binary);
    float in[32], out[32];
    while (input.read(reinterpret_cast<char*>(in), sizeof in) || input.gcount()) {
        const int n = static_cast<int>(input.gcount() / sizeof(float));
        NAM_SAMPLE x[32], y[32];
        std::copy(in, in+n, x);
        NAM_SAMPLE *px = x, *py = y;
        dsp->process(&px, &py, n);
        std::copy(y, y+n, out);
        output.write(reinterpret_cast<const char*>(out), n*sizeof(float));
    }
    return output.good() ? 0 : 1;
}
