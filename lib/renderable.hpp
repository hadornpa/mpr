#pragma once
#include <cuda_gl_interop.h>
#include <cuda_runtime.h>
#include <libfive/tree/tree.hpp>

#include "check.hpp"
#include "clause.hpp"
#include "gpu_interval.hpp"
#include "image.hpp"
#include "parameters.hpp"
#include "subtapes.hpp"
#include "tape.hpp"
#include "tiles.hpp"
#include "view.hpp"

class TileRenderer {
public:
    TileRenderer(const Tape& tape, Image& image);
    ~TileRenderer();

    // These are blocks of data which should be indexed as i[threadIdx.x]
    using Registers = Interval[LIBFIVE_CUDA_TILE_THREADS];
    using ChoiceArray = uint64_t[LIBFIVE_CUDA_TILE_THREADS];
    using ActiveArray = uint8_t[LIBFIVE_CUDA_TILE_THREADS];

    // Evaluates the given tile.
    //      Filled -> Pushes it to the list of filed tiles
    //      Ambiguous -> Pushes it to the list of active tiles and builds tape
    //      Empty -> Does nothing
    //  Reverses the tapes
    __device__ void check(const uint32_t tile, const View& v);

    // Fills in the given (filled) tile in the image
    __device__ void drawFilled(const uint32_t tile);

    const Tape& tape;
    Image& image;

    Tiles<64, 2> tiles;

protected:
    Registers* __restrict__ const regs;
    ActiveArray* __restrict__ const active;
    ChoiceArray* __restrict__ const choices;

    TileRenderer(const TileRenderer& other)=delete;
    TileRenderer& operator=(const TileRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

class SubtileRenderer {
public:
    SubtileRenderer(const Tape& tape, Image& image, Tiles<64, 2>& prev);
    ~SubtileRenderer();

    using Registers = Interval[LIBFIVE_CUDA_SUBTILES_PER_TILE *
                               LIBFIVE_CUDA_REFINE_TILES];
    using ActiveArray = uint8_t[LIBFIVE_CUDA_SUBTILES_PER_TILE *
                                LIBFIVE_CUDA_REFINE_TILES];
    using ChoiceArray = uint64_t[LIBFIVE_CUDA_SUBTILES_PER_TILE *
                                 LIBFIVE_CUDA_REFINE_TILES];

    // Same functions as in TileRenderer, but these take a subtape because
    // they're refining a tile into subtiles
    __device__ void check(
            const uint32_t subtile,
            const uint32_t tile,
            const View& v);
    __device__ void drawFilled(const uint32_t tile);

    // Refines a tile tape into a subtile tape based on choices
    __device__ void buildTape(const uint32_t subtile,
                              const uint32_t tile);
    const Tape& tape;
    Image& image;

    Tiles<64, 2>& tiles;   // Reference to tiles generated in previous stage
    Tiles<8, 2> subtiles; // New tiles generated in this stage

protected:
    Registers* __restrict__ const regs;
    ActiveArray* __restrict__ const active;
    ChoiceArray* __restrict__ const choices;

    SubtileRenderer(const SubtileRenderer& other)=delete;
    SubtileRenderer& operator=(const SubtileRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

template <unsigned SUBTILE_SIZE_PX, unsigned DIMENSION>
class PixelRenderer {
public:
    PixelRenderer(const Tape& tape, Image& image, const Tiles<SUBTILE_SIZE_PX, DIMENSION>& prev);
    ~PixelRenderer();

    constexpr static unsigned __host__ __device__ pixelsPerSubtile() {
        return pow(SUBTILE_SIZE_PX, DIMENSION);
    }

    using FloatRegisters = float[pixelsPerSubtile() *
                                 LIBFIVE_CUDA_RENDER_SUBTILES];

    // Draws the given tile, starting from the given subtape
    __device__ void draw(const uint32_t subtile, const View& v);

    const Tape& tape;
    Image& image;

    // Reference to tiles generated in previous stage
    const Tiles<SUBTILE_SIZE_PX, DIMENSION>& subtiles;

protected:
    FloatRegisters* __restrict__ const regs;

    PixelRenderer(const PixelRenderer& other)=delete;
    PixelRenderer& operator=(const PixelRenderer& other)=delete;
};

////////////////////////////////////////////////////////////////////////////////

class Renderable {
public:
    class Deleter {
    public:
        void operator()(Renderable* r);
    };

    using Handle = std::unique_ptr<Renderable, Deleter>;

    // Returns a GPU-allocated Renderable struct
    static Handle build(libfive::Tree tree, uint32_t image_size_px);
    ~Renderable();
    void run(const View& v);

    static cudaGraphicsResource* registerTexture(GLuint t);
    void copyToTexture(cudaGraphicsResource* gl_tex, bool append);

    Image image;
    Tape tape;

protected:
    Renderable(libfive::Tree tree, uint32_t image_size_px);

    cudaStream_t streams[2];

    TileRenderer tile_renderer;
    SubtileRenderer subtile_renderer;
    PixelRenderer<8, 2> pixel_renderer;

    Renderable(const Renderable& other)=delete;
    Renderable& operator=(const Renderable& other)=delete;
};
