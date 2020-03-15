#include "clause.hpp"
#include "context.hpp"
#include "parameters.hpp"
#include "tape.hpp"

#include "gpu_deriv.hpp"
#include "gpu_interval.hpp"
#include "gpu_opcode.hpp"

namespace libfive {
namespace cuda {

static inline __device__
int4 unpack(int32_t pos, int32_t tiles_per_side)
{
    return make_int4(pos % tiles_per_side,
                    (pos / tiles_per_side) % tiles_per_side,
                    (pos / tiles_per_side) / tiles_per_side,
                     pos % (tiles_per_side * tiles_per_side));
}

////////////////////////////////////////////////////////////////////////////////
static __global__
void preload_tiles(TileNode* const __restrict__ in_tiles,
                   const int32_t in_tile_count)
{
    const int32_t tile_index = threadIdx.x + blockIdx.x * blockDim.x;
    if (tile_index >= in_tile_count) {
        return;
    }

    in_tiles[tile_index].position = tile_index;
    in_tiles[tile_index].tape = 0;
    in_tiles[tile_index].next = -1;
}

__global__
void calculate_intervals(const TileNode* const __restrict__ in_tiles,
                         const uint32_t in_tile_count,
                         const uint32_t tiles_per_side,
                         const Eigen::Matrix4f mat,
                         Interval* const __restrict__ values)
{
    const uint32_t tile_index = threadIdx.x + blockIdx.x * blockDim.x;
    if (tile_index >= in_tile_count) {
        return;
    }

    const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
    const Interval ix = {(pos.x / (float)tiles_per_side - 0.5f) * 2.0f,
                   ((pos.x + 1) / (float)tiles_per_side - 0.5f) * 2.0f};
    const Interval iy = {(pos.y / (float)tiles_per_side - 0.5f) * 2.0f,
                   ((pos.y + 1) / (float)tiles_per_side - 0.5f) * 2.0f};
    const Interval iz = {(pos.z / (float)tiles_per_side - 0.5f) * 2.0f,
                   ((pos.z + 1) / (float)tiles_per_side - 0.5f) * 2.0f};

    Interval ix_, iy_, iz_, iw_;
    ix_ = mat(0, 0) * ix +
          mat(0, 1) * iy +
          mat(0, 2) * iz + mat(0, 3);
    iy_ = mat(1, 0) * ix +
          mat(1, 1) * iy +
          mat(1, 2) * iz + mat(1, 3);
    iz_ = mat(2, 0) * ix +
          mat(2, 1) * iy +
          mat(2, 2) * iz + mat(2, 3);
    iw_ = mat(3, 0) * ix +
          mat(3, 1) * iy +
          mat(3, 2) * iz + mat(3, 3);

    // Projection!
    ix_ = ix_ / iw_;
    iy_ = iy_ / iw_;
    iz_ = iz_ / iw_;

    values[tile_index * 3] = ix_;
    values[tile_index * 3 + 1] = iy_;
    values[tile_index * 3 + 2] = iz_;
}

__global__
void eval_tiles_i(uint64_t* const __restrict__ tape_data,
                  int32_t* const __restrict__ tape_index,
                  int32_t* const __restrict__ image,
                  const uint32_t tiles_per_side,

                  TileNode* const __restrict__ in_tiles,
                  const int32_t in_tile_count,

                  const Interval* __restrict__ values)
{
    const int32_t tile_index = threadIdx.x + blockIdx.x * blockDim.x;
    if (tile_index >= in_tile_count) {
        return;
    }

    // Check to see if we're masked
    if (in_tiles[tile_index].position == -1) {
        return;
    }

    Interval slots[128];
    slots[((const uint8_t*)tape_data)[1]] = values[tile_index * 3];
    slots[((const uint8_t*)tape_data)[2]] = values[tile_index * 3 + 1];
    slots[((const uint8_t*)tape_data)[3]] = values[tile_index * 3 + 2];

    // Pick out the tape based on the pointer stored in the tiles list
    const uint64_t* __restrict__ data = &tape_data[in_tiles[tile_index].tape];

    uint32_t choices[128] = {0};
    int choice_index = 0;
    bool has_any_choice = false;

    while (1) {
        const uint64_t d = *++data;
        if (!OP(&d)) {
            break;
        }
        switch (OP(&d)) {
            case GPU_OP_JUMP: data += JUMP_TARGET(&d); continue;

#define lhs slots[I_LHS(&d)]
#define rhs slots[I_RHS(&d)]
#define imm IMM(&d)
#define out slots[I_OUT(&d)]

            case GPU_OP_SQUARE_LHS: out = square(lhs); break;
            case GPU_OP_SQRT_LHS:   out = sqrt(lhs); break;
            case GPU_OP_NEG_LHS:    out = -lhs; break;
            case GPU_OP_SIN_LHS:    out = sin(lhs); break;
            case GPU_OP_COS_LHS:    out = cos(lhs); break;
            case GPU_OP_ASIN_LHS:   out = asin(lhs); break;
            case GPU_OP_ACOS_LHS:   out = acos(lhs); break;
            case GPU_OP_ATAN_LHS:   out = atan(lhs); break;
            case GPU_OP_EXP_LHS:    out = exp(lhs); break;
            case GPU_OP_ABS_LHS:    out = abs(lhs); break;
            case GPU_OP_LOG_LHS:    out = log(lhs); break;

            // Commutative opcodes
            case GPU_OP_ADD_LHS_IMM: out = lhs + imm; break;
            case GPU_OP_ADD_LHS_RHS: out = lhs + rhs; break;
            case GPU_OP_MUL_LHS_IMM: out = lhs * imm; break;
            case GPU_OP_MUL_LHS_RHS: out = lhs * rhs; break;

#define CHOICE(f, a, b) {                                           \
    int c = 0;                                                      \
    out = f(a, b, c);                                               \
    choices[choice_index / 16] |= (c << ((choice_index % 16) * 2)); \
    choice_index++;                                                 \
    has_any_choice |= (c != 0);                                     \
    break;                                                          \
}
            case GPU_OP_MIN_LHS_IMM: CHOICE(min, lhs, imm);
            case GPU_OP_MIN_LHS_RHS: CHOICE(min, lhs, rhs);
            case GPU_OP_MAX_LHS_IMM: CHOICE(max, lhs, imm);
            case GPU_OP_MAX_LHS_RHS: CHOICE(max, lhs, rhs);

            // Non-commutative opcodes
            case GPU_OP_SUB_LHS_IMM: out = lhs - imm; break;
            case GPU_OP_SUB_IMM_RHS: out = imm - rhs; break;
            case GPU_OP_SUB_LHS_RHS: out = lhs - rhs; break;
            case GPU_OP_DIV_LHS_IMM: out = lhs / imm; break;
            case GPU_OP_DIV_IMM_RHS: out = imm / rhs; break;
            case GPU_OP_DIV_LHS_RHS: out = lhs / rhs; break;

            case GPU_OP_COPY_IMM: out = Interval(imm); break;
            case GPU_OP_COPY_LHS: out = lhs; break;
            case GPU_OP_COPY_RHS: out = rhs; break;

            default: assert(false);
        }
#undef lhs
#undef rhs
#undef imm
#undef out
    }

    // Check the result
    const uint8_t i_out = I_OUT(data);
#if 0
    printf("%u:%u: [%f %f] [%f %f] [%f %f] => [%f %f]\n",
            blockIdx.x, threadIdx.x,
            values[tile_index * 3].lower(),
            values[tile_index * 3].upper(),
            values[tile_index * 3 + 1].lower(),
            values[tile_index * 3 + 1].upper(),
            values[tile_index * 3 + 2].lower(),
            values[tile_index * 3 + 2].upper(),
            slots[i_out].lower(),
            slots[i_out].upper());
#endif

    if (slots[i_out].lower() > 0.0f) {
        in_tiles[tile_index].position = -1;
        return;
    }

    // Masked
    const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
    if (image[pos.w] > pos.z) {
        in_tiles[tile_index].position = -1;
        return;
    }

    // Filled
    if (slots[i_out].upper() < 0.0f) {
        const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
        in_tiles[tile_index].position = -1;
        atomicMax(&image[pos.w], pos.z);
        return;
    }

    if (!has_any_choice) {
        return;
    }

    ////////////////////////////////////////////////////////////////////////////
    // Tape pushing!
    // Use this array to track which slots are active
    int* const __restrict__ active = (int*)slots;
    for (unsigned i=0; i < 128; ++i) {
        active[i] = false;
    }
    active[i_out] = true;

    // Claim a chunk of tape
    int32_t out_index = atomicAdd(tape_index, SUBTAPE_CHUNK_SIZE);
    int32_t out_offset = SUBTAPE_CHUNK_SIZE;
    assert(out_index + out_offset < NUM_SUBTAPES *
                                    SUBTAPE_CHUNK_SIZE);

    // Write out the end of the tape, which is the same as the ending
    // of the previous tape (0 opcode, with i_out as the last slot)
    out_offset--;
    tape_data[out_index + out_offset] = *data;

    while (1) {
        uint64_t d = *--data;
        if (!OP(&d)) {
            break;
        }
        const uint8_t op = OP(&d);
        if (op == GPU_OP_JUMP) {
            data += JUMP_TARGET(&d);
            continue;
        }

        const bool has_choice = op >= GPU_OP_MIN_LHS_IMM &&
                                op <= GPU_OP_MAX_LHS_RHS;
        choice_index -= has_choice;

        const uint8_t i_out = I_OUT(&d);
        if (!active[i_out]) {
            continue;
        }

        assert(!has_choice || choice_index >= 0);

        const int choice = has_choice
            ? ((choices[choice_index / 16] >>
              ((choice_index % 16) * 2)) & 3)
            : 0;

        // If we're about to write a new piece of data to the tape,
        // (and are done with the current chunk), then we need to
        // add another link to the linked list.
        --out_offset;
        if (out_offset == 0) {
            const int32_t prev_index = out_index;
            out_index = atomicAdd(tape_index, SUBTAPE_CHUNK_SIZE);
            out_offset = SUBTAPE_CHUNK_SIZE;
            assert(out_index + out_offset < NUM_SUBTAPES *
                                            SUBTAPE_CHUNK_SIZE);
            --out_offset;

            // Forward-pointing link
            OP(&tape_data[out_index + out_offset]) = GPU_OP_JUMP;
            const int32_t delta = (int32_t)prev_index -
                                  (int32_t)(out_index + out_offset);
            JUMP_TARGET(&tape_data[out_index + out_offset]) = delta;

            // Backward-pointing link
            OP(&tape_data[prev_index]) = GPU_OP_JUMP;
            JUMP_TARGET(&tape_data[prev_index]) = -delta;

            // We've written the jump, so adjust the offset again
            --out_offset;
        }

        active[i_out] = false;
        if (choice == 0) {
            const uint8_t i_lhs = I_LHS(&d);
            if (i_lhs) {
                active[i_lhs] = true;
            }
            const uint8_t i_rhs = I_RHS(&d);
            if (i_rhs) {
                active[i_rhs] = true;
            }
        } else if (choice == 1 /* LHS */) {
            // The non-immediate is always the LHS in commutative ops, and
            // min/max (the only clauses that produce a choice) are commutative
            const uint8_t i_lhs = I_LHS(&d);
            active[i_lhs] = true;
            if (i_lhs == i_out) {
                ++out_offset;
                continue;
            } else {
                OP(&d) = GPU_OP_COPY_LHS;
            }
        } else if (choice == 2 /* RHS */) {
            const uint8_t i_rhs = I_RHS(&d);
            if (i_rhs) {
                active[i_rhs] = true;
                if (i_rhs == i_out) {
                    ++out_offset;
                    continue;
                } else {
                    OP(&d) = GPU_OP_COPY_RHS;
                }
            } else {
                OP(&d) = GPU_OP_COPY_IMM;
            }
        }
        tape_data[out_index + out_offset] = d;
    }

    // Write the beginning of the tape
    out_offset--;
    tape_data[out_index + out_offset] = *data;

    // Record the beginning of the tape in the output tile
    in_tiles[tile_index].tape = out_index + out_offset;
}

////////////////////////////////////////////////////////////////////////////////

__global__
void mask_filled_tiles(int32_t* const __restrict__ image,
                       const uint32_t tiles_per_side,

                       TileNode* const __restrict__ in_tiles,
                       const int32_t in_tile_count)
{
    const int32_t tile_index = threadIdx.x + blockIdx.x * blockDim.x;
    if (tile_index >= in_tile_count) {
        return;
    }

    const int32_t tile = in_tiles[tile_index].position;
    // Already marked as filled or empty
    if (tile == -1) {
        return;
    }

    const int4 pos = unpack(tile, tiles_per_side);

    // If this tile is completely masked by the image, then skip it
    if (image[pos.w] > pos.z) {
        in_tiles[tile_index].position = -1;
    }
}

////////////////////////////////////////////////////////////////////////////////

// Sets the tile.next to an index in the upcoming tile list, without
// actually doing any work (since that list may not be allocated yet)
__global__
void assign_next_nodes(TileNode* const __restrict__ in_tiles,
                       const int32_t in_tile_count,

                       int32_t* __restrict__ const num_active_tiles)
{
    const int32_t tile_index = threadIdx.x + blockIdx.x * blockDim.x;
    if (tile_index >= in_tile_count) {
        return;
    }

    const bool is_active = tile_index < in_tile_count &&
                           in_tiles[tile_index].position != -1;

    // Do two levels of accumulation, to reduce atomic pressure on a single
    // global variable.  Does this help?  Who knows!
    __shared__ int local_offset;
    if (threadIdx.x == 0) {
        local_offset = 0;
    }
    __syncthreads();

    int my_offset;
    if (is_active) {
        my_offset = atomicAdd(&local_offset, 1);
    }
    __syncthreads();

    // Only one thread gets to contribute to the global offset
    if (threadIdx.x == 0) {
        local_offset = atomicAdd(num_active_tiles, local_offset);
    }
    __syncthreads();

    if (is_active) {
        in_tiles[tile_index].next = local_offset + my_offset;
    } else {
        in_tiles[tile_index].next = -1;
    }
}

// Copies each active tile into 64 subtiles
__global__
void subdivide_active_tiles(
        const TileNode* const __restrict__ in_tiles,
        const int32_t in_tile_count,
        const int32_t tiles_per_side,
        TileNode* const __restrict__ out_tiles)
{
    const int32_t index = threadIdx.x + blockIdx.x * blockDim.x;
    const int32_t subtile_index = index % 64;
    const int32_t tile_index = index / 64;
    if (tile_index >= in_tile_count || in_tiles[tile_index].next == -1) {
        return;
    }

    const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
    const int32_t subtiles_per_side = tiles_per_side * 4;

    const int4 sub = unpack(subtile_index, 4);
    const int32_t sx = pos.x * 4 + sub.x;
    const int32_t sy = pos.y * 4 + sub.y;
    const int32_t sz = pos.z * 4 + sub.z;
    const int32_t next_tile =
        sx +
        sy * subtiles_per_side +
        sz * subtiles_per_side * subtiles_per_side;

    const int t = in_tiles[tile_index].next * 64 + subtile_index;
    out_tiles[t].position = next_tile;
    out_tiles[t].tape = in_tiles[tile_index].tape;
    out_tiles[t].next = -1;
}

// Copies each active tile into the out_tiles list, clearing its `next` value.
// This is used right before per-pixel evaluation, which wants a compact list
// of active tiles, but doesn't need to subdivide them by 64 itself.
__global__
void copy_active_tiles(TileNode* const __restrict__ in_tiles,
                       const int32_t in_tile_count,
                       const int32_t tiles_per_side,
                       TileNode* const __restrict__ out_tiles)
{
    const int32_t tile_index = threadIdx.x + blockIdx.x * blockDim.x;
    if (tile_index >= in_tile_count || in_tiles[tile_index].next == -1) {
        return;
    }
    const int t = in_tiles[tile_index].next;
    out_tiles[t].position = in_tiles[tile_index].position;
    out_tiles[t].tape = in_tiles[tile_index].tape;
    out_tiles[t].next = -1;
    in_tiles[tile_index].next = -1;
}

////////////////////////////////////////////////////////////////////////////////

__global__
void copy_filled(const int32_t* __restrict__ prev,
                 int32_t* __restrict__ image,
                 const int32_t image_size_px)
{
    const int32_t x = threadIdx.x + blockIdx.x * blockDim.x;
    const int32_t y = threadIdx.y + blockIdx.y * blockDim.y;

    if (x < image_size_px && y < image_size_px) {
        int32_t t = prev[x / 4 + y / 4 * (image_size_px / 4)];
        if (t) {
            image[x + y * image_size_px] = t * 4 + 3;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////

__global__
void calculate_voxels(const TileNode* const __restrict__ in_tiles,
                      const uint32_t in_tile_count,
                      const uint32_t tiles_per_side,
                      const Eigen::Matrix4f mat,
                      float2* const __restrict__ values)
{
    // Each tile is executed by 32 threads (one for each pair of voxels).
    //
    // This is different from the eval_tiles_i function, which evaluates one
    // tile per thread, because the tiles are already expanded by 64x by the
    // time they're stored in the in_tiles list.
    const int32_t voxel_index = threadIdx.x + blockIdx.x * blockDim.x;
    const int32_t tile_index = voxel_index / 32;

    if (tile_index >= in_tile_count) {
        return;
    }
    const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
    const int4 sub = unpack(threadIdx.x % 32, 4);

    const int32_t px = pos.x * 4 + sub.x;
    const int32_t py = pos.y * 4 + sub.y;
    const int32_t pz_a = pos.z * 4 + sub.z;

    const float size_recip = 1.0f / (tiles_per_side * 4);

    const float fx = ((px + 0.5f) * size_recip - 0.5f) * 2.0f;
    const float fy = ((py + 0.5f) * size_recip - 0.5f) * 2.0f;
    const float fz_a = ((pz_a + 0.5f) * size_recip - 0.5f) * 2.0f;

    // Otherwise, calculate the X/Y/Z values
    const float fw_a = mat(3, 0) * fx +
                       mat(3, 1) * fy +
                       mat(3, 2) * fz_a + mat(3, 3);
    for (unsigned i=0; i < 3; ++i) {
        values[voxel_index * 3 + i].x =
            (mat(i, 0) * fx +
             mat(i, 1) * fy +
             mat(i, 2) * fz_a + mat(i, 3)) / fw_a;
    }

    // Do the same calculation for the second pixel
    const int32_t pz_b = pos.z * 4 + sub.z + 2;
    const float fz_b = ((pz_b + 0.5f) * size_recip - 0.5f) * 2.0f;
    const float fw_b = mat(3, 0) * fx +
                       mat(3, 1) * fy +
                       mat(3, 2) * fz_b + mat(3, 3);

    for (unsigned i=0; i < 3; ++i) {
        values[voxel_index * 3 + i].y =
            (mat(i, 0) * fx +
             mat(i, 1) * fy +
             mat(i, 2) * fz_b + mat(i, 3)) / fw_b;
    }
}

__global__
void eval_voxels_f(const uint64_t* const __restrict__ tape_data,
                   int32_t* const __restrict__ image,
                   const uint32_t tiles_per_side,

                   TileNode* const __restrict__ in_tiles,
                   const int32_t in_tile_count,

                   const float2* const __restrict__ values)
{
    // Each tile is executed by 32 threads (one for each pair of voxels, so
    // we can do all of our load/stores as float2s and make memory happier).
    //
    // This is different from the eval_tiles_i function, which evaluates one
    // tile per thread, because the tiles are already expanded by 64x by the
    // time they're stored in the in_tiles list.
    const int32_t voxel_index = threadIdx.x + blockIdx.x * blockDim.x;
    const int32_t tile_index = voxel_index / 32;
    if (tile_index >= in_tile_count) {
        return;
    }

    {   // Load values into registers, subdividing by 4x on each axis
        const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
        const int4 sub = unpack(threadIdx.x % 32, 4);

        const int32_t px = pos.x * 4 + sub.x;
        const int32_t py = pos.y * 4 + sub.y;
        const int32_t pz = pos.z * 4 + sub.z;

        // Early return if this pixel won't ever be filled
        if (image[px + py * tiles_per_side * 4] >= pz + 2) {
            return;
        }
    }

    float2 slots[128];

    // Pick out the tape based on the pointer stored in the tiles list
    const uint64_t* __restrict__ data = &tape_data[in_tiles[tile_index].tape];
    slots[((const uint8_t*)tape_data)[1]] = values[voxel_index * 3];
    slots[((const uint8_t*)tape_data)[2]] = values[voxel_index * 3 + 1];
    slots[((const uint8_t*)tape_data)[3]] = values[voxel_index * 3 + 2];

    while (1) {
        const uint64_t d = *++data;
        if (!OP(&d)) {
            break;
        }
        switch (OP(&d)) {
            case GPU_OP_JUMP: data += JUMP_TARGET(&d); continue;

#define lhs slots[I_LHS(&d)]
#define rhs slots[I_RHS(&d)]
#define imm IMM(&d)
#define out slots[I_OUT(&d)]

            case GPU_OP_SQUARE_LHS: out = make_float2(lhs.x * lhs.x, lhs.y * lhs.y); break;
            case GPU_OP_SQRT_LHS: out = make_float2(sqrtf(lhs.x), sqrtf(lhs.y)); break;
            case GPU_OP_NEG_LHS: out = make_float2(-lhs.x, -lhs.y); break;
            case GPU_OP_SIN_LHS: out = make_float2(sinf(lhs.x), sinf(lhs.y)); break;
            case GPU_OP_COS_LHS: out = make_float2(cosf(lhs.x), cosf(lhs.y)); break;
            case GPU_OP_ASIN_LHS: out = make_float2(asinf(lhs.x), asinf(lhs.y)); break;
            case GPU_OP_ACOS_LHS: out = make_float2(acosf(lhs.x), acosf(lhs.y)); break;
            case GPU_OP_ATAN_LHS: out = make_float2(atanf(lhs.x), atanf(lhs.y)); break;
            case GPU_OP_EXP_LHS: out = make_float2(expf(lhs.x), expf(lhs.y)); break;
            case GPU_OP_ABS_LHS: out = make_float2(fabsf(lhs.x), fabsf(lhs.y)); break;
            case GPU_OP_LOG_LHS: out = make_float2(logf(lhs.x), logf(lhs.y)); break;

            // Commutative opcodes
            case GPU_OP_ADD_LHS_IMM: out = make_float2(lhs.x + imm, lhs.y + imm); break;
            case GPU_OP_ADD_LHS_RHS: out = make_float2(lhs.x + rhs.x, lhs.y + rhs.y); break;
            case GPU_OP_MUL_LHS_IMM: out = make_float2(lhs.x * imm, lhs.y * imm); break;
            case GPU_OP_MUL_LHS_RHS: out = make_float2(lhs.x * rhs.x, lhs.y * rhs.y); break;
            case GPU_OP_MIN_LHS_IMM: out = make_float2(fminf(lhs.x, imm), fminf(lhs.y, imm)); break;
            case GPU_OP_MIN_LHS_RHS: out = make_float2(fminf(lhs.x, rhs.x), fminf(lhs.y, rhs.y)); break;
            case GPU_OP_MAX_LHS_IMM: out = make_float2(fmaxf(lhs.x, imm), fmaxf(lhs.y, imm)); break;
            case GPU_OP_MAX_LHS_RHS: out = make_float2(fmaxf(lhs.x, rhs.x), fmaxf(lhs.y, rhs.y)); break;

            // Non-commutative opcodes
            case GPU_OP_SUB_LHS_IMM: out = make_float2(lhs.x - imm, lhs.y - imm); break;
            case GPU_OP_SUB_IMM_RHS: out = make_float2(imm - rhs.x, imm - rhs.y); break;
            case GPU_OP_SUB_LHS_RHS: out = make_float2(lhs.x - rhs.x, lhs.y - rhs.y); break;

            case GPU_OP_DIV_LHS_IMM: out = make_float2(lhs.x / imm, lhs.y / imm); break;
            case GPU_OP_DIV_IMM_RHS: out = make_float2(imm / rhs.x, imm / rhs.y); break;
            case GPU_OP_DIV_LHS_RHS: out = make_float2(lhs.x / rhs.x, lhs.y / rhs.y); break;

            case GPU_OP_COPY_IMM: out = make_float2(imm, imm); break;
            case GPU_OP_COPY_LHS: out = make_float2(lhs.x, lhs.y); break;
            case GPU_OP_COPY_RHS: out = make_float2(rhs.x, rhs.y); break;

#undef lhs
#undef rhs
#undef imm
#undef out
        }
    }

    // Check the result
    const uint8_t i_out = I_OUT(data);

    // The second voxel is always higher in Z, so it masks the lower voxel
    if (slots[i_out].y < 0.0f) {
        const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
        const int4 sub = unpack(threadIdx.x % 32, 4);
        const int32_t px = pos.x * 4 + sub.x;
        const int32_t py = pos.y * 4 + sub.y;
        const int32_t pz = pos.z * 4 + sub.z + 2;

        atomicMax(&image[px + py * tiles_per_side * 4], pz);
    } else if (slots[i_out].x < 0.0f) {
        const int4 pos = unpack(in_tiles[tile_index].position, tiles_per_side);
        const int4 sub = unpack(threadIdx.x % 32, 4);
        const int32_t px = pos.x * 4 + sub.x;
        const int32_t py = pos.y * 4 + sub.y;
        const int32_t pz = pos.z * 4 + sub.z;

        atomicMax(&image[px + py * tiles_per_side * 4], pz);
    }
}

////////////////////////////////////////////////////////////////////////////////

__global__
void eval_pixels_d(const uint64_t* const __restrict__ tape_data,
                   const int32_t* const __restrict__ image,
                   uint32_t* const __restrict__ output,
                   const uint32_t image_size_px,

                   Eigen::Matrix4f mat,

                   const TileNode* const __restrict__ tiles,
                   const TileNode* const __restrict__ subtiles,
                   const TileNode* const __restrict__ microtiles)
{
    const int32_t px = threadIdx.x + blockIdx.x * blockDim.x;
    const int32_t py = threadIdx.y + blockIdx.y * blockDim.y;
    if (px >= image_size_px || py >= image_size_px) {
        return;
    }

    const int32_t pxy = px + py * image_size_px;
    int32_t pz = image[pxy];
    if (pz == 0) {
        return;
    }
    pz += 1; // Move slightly in front of the surface

    Deriv slots[128];

    {   // Calculate size and load into initial slots
        const float size_recip = 1.0f / image_size_px;

        const float fx = ((px + 0.5f) * size_recip - 0.5f) * 2.0f;
        const float fy = ((py + 0.5f) * size_recip - 0.5f) * 2.0f;
        const float fz = ((pz + 0.5f) * size_recip - 0.5f) * 2.0f;

        // Otherwise, calculate the X/Y/Z values
        const float fw_ = mat(3, 0) * fx +
                          mat(3, 1) * fy +
                          mat(3, 2) * fz + mat(3, 3);
        for (unsigned i=0; i < 3; ++i) {
            slots[((const uint8_t*)tape_data)[i + 1]] = Deriv(
                (mat(i, 0) * fx +
                 mat(i, 1) * fy +
                 mat(i, 2) * fz + mat(0, 3)) / fw_);
        }
        slots[((const uint8_t*)tape_data)[1]].v.x = 1.0f;
        slots[((const uint8_t*)tape_data)[2]].v.y = 1.0f;
        slots[((const uint8_t*)tape_data)[3]].v.z = 1.0f;
    }


    const uint64_t* __restrict__ data = tape_data;

    {   // Pick out the tape based on the pointer stored in the tiles list
        const int32_t tile_x = px / 64;
        const int32_t tile_y = py / 64;
        const int32_t tile_z = pz / 64;
        const int32_t tile = tile_x +
                             tile_y * (image_size_px / 64) +
                             tile_z * (image_size_px / 64) * (image_size_px / 64);

        if (tiles[tile].next == -1) {
            data = &tape_data[tiles[tile].tape];
        } else {
            const int32_t sx = (px % 64) / 16;
            const int32_t sy = (py % 64) / 16;
            const int32_t sz = (pz % 64) / 16;
            const int32_t subtile = tiles[tile].next * 64 +
                                    sx +
                                    sy * 4 +
                                    sz * 16;

            if (subtiles[subtile].next == -1) {
                data = &tape_data[subtiles[subtile].tape];
            } else {
                const int32_t ux = (px % 16) / 4;
                const int32_t uy = (py % 16) / 4;
                const int32_t uz = (pz % 16) / 4;
                const int32_t microtile = subtiles[subtile].next * 64 +
                                        ux +
                                        uy * 4 +
                                        uz * 16;
                data = &tape_data[microtiles[microtile].tape];
            }
        }
    }

    while (1) {
        const uint64_t d = *++data;
        if (!OP(&d)) {
            break;
        }
        switch (OP(&d)) {
            case GPU_OP_JUMP: data += JUMP_TARGET(&d); continue;

#define lhs slots[I_LHS(&d)]
#define rhs slots[I_RHS(&d)]
#define imm IMM(&d)
#define out slots[I_OUT(&d)]

            case GPU_OP_SQUARE_LHS: out = lhs * lhs; break;
            case GPU_OP_SQRT_LHS: out = sqrt(lhs); break;
            case GPU_OP_NEG_LHS: out = -lhs; break;
            case GPU_OP_SIN_LHS: out = sin(lhs); break;
            case GPU_OP_COS_LHS: out = cos(lhs); break;
            case GPU_OP_ASIN_LHS: out = asin(lhs); break;
            case GPU_OP_ACOS_LHS: out = acos(lhs); break;
            case GPU_OP_ATAN_LHS: out = atan(lhs); break;
            case GPU_OP_EXP_LHS: out = exp(lhs); break;
            case GPU_OP_ABS_LHS: out = abs(lhs); break;
            case GPU_OP_LOG_LHS: out = log(lhs); break;

            // Commutative opcodes
            case GPU_OP_ADD_LHS_IMM: out = lhs + imm; break;
            case GPU_OP_ADD_LHS_RHS: out = lhs + rhs; break;
            case GPU_OP_MUL_LHS_IMM: out = lhs * imm; break;
            case GPU_OP_MUL_LHS_RHS: out = lhs * rhs; break;
            case GPU_OP_MIN_LHS_IMM: out = min(lhs, imm); break;
            case GPU_OP_MIN_LHS_RHS: out = min(lhs, rhs); break;
            case GPU_OP_MAX_LHS_IMM: out = max(lhs, imm); break;
            case GPU_OP_MAX_LHS_RHS: out = max(lhs, rhs); break;

            // Non-commutative opcodes
            case GPU_OP_SUB_LHS_IMM: out = lhs - imm; break;
            case GPU_OP_SUB_IMM_RHS: out = imm - rhs; break;
            case GPU_OP_SUB_LHS_RHS: out = lhs - rhs; break;

            case GPU_OP_DIV_LHS_IMM: out = lhs / imm; break;
            case GPU_OP_DIV_IMM_RHS: out = imm / rhs; break;
            case GPU_OP_DIV_LHS_RHS: out = lhs / rhs; break;

            case GPU_OP_COPY_IMM: out = Deriv(imm); break;
            case GPU_OP_COPY_LHS: out = lhs; break;
            case GPU_OP_COPY_RHS: out = rhs; break;

#undef lhs
#undef rhs
#undef imm
#undef out
        }
    }

    const uint8_t i_out = I_OUT(data);
    const Deriv result = slots[i_out];
    float norm = sqrtf(powf(result.dx(), 2) +
                       powf(result.dy(), 2) +
                       powf(result.dz(), 2));
    uint8_t dx = (result.dx() / norm) * 127 + 128;
    uint8_t dy = (result.dy() / norm) * 127 + 128;
    uint8_t dz = (result.dz() / norm) * 127 + 128;
    output[pxy] = (0xFF << 24) | (dz << 16) | (dy << 8) | dx;
}

////////////////////////////////////////////////////////////////////////////////

void Context::render(const Tape& tape, const Eigen::Matrix4f mat) {
    // Reset the tape index and copy the tape to the beginning of the
    // context's tape buffer area.
    *tape_index = tape.length;
    cudaMemcpy(tape_data.get(), tape.data.get(),
               sizeof(uint64_t) * tape.length,
               cudaMemcpyDeviceToDevice);

    ////////////////////////////////////////////////////////////////////////////
    // Evaluation of 64x64x64 tiles
    ////////////////////////////////////////////////////////////////////////////

    // Reset all of the data arrays
    for (unsigned i=0; i < 4; ++i) {
        const unsigned tile_size_px = 64 / (1 << (i * 2));
        CUDA_CHECK(cudaMemset(stages[i].filled.get(), 0, sizeof(int32_t) *
                              pow(image_size_px / tile_size_px, 2)));
    }
    CUDA_CHECK(cudaMemset(normals.get(), 0, sizeof(uint32_t) *
                          pow(image_size_px, 2)));

    // Go the whole list of first-stage tiles, assigning each to
    // be [position, tape = 0, next = -1]
    unsigned count = pow(image_size_px / 64, 3);
    unsigned num_blocks = (count + NUM_THREADS - 1) / NUM_THREADS;
    preload_tiles<<<num_blocks, NUM_THREADS>>>(stages[0].tiles.get(), count);

    // Iterate over 64^3, 16^3, 4^3 tiles
    for (unsigned i=0; i < 3; ++i) {
        //printf("BEGINNING STAGE %u\n", i);
        const unsigned tile_size_px = 64 / (1 << (i * 2));
        const unsigned num_blocks = (count + NUM_THREADS - 1) / NUM_THREADS;

        if (values_size < num_blocks * NUM_THREADS * 3) {
            values.reset(CUDA_MALLOC(Interval, num_blocks * NUM_THREADS * 3));
            values_size = num_blocks * NUM_THREADS * 3;
        }

        // Unpack position values into interval X/Y/Z in the values array
        // This is done in a separate kernel to avoid bloating the
        // eval_tiles_i kernel with more registers, which is detrimental
        // to occupancy.
        calculate_intervals<<<num_blocks, NUM_THREADS>>>(
            stages[i].tiles.get(),
            count,
            image_size_px / tile_size_px,
            mat,
            reinterpret_cast<Interval*>(values.get()));

        // Mark every tile which is covered in the image as masked,
        // which means it will be skipped later on.  We do this again below,
        // but it's basically free, so we should do it here and simplify
        // the logic in eval_tiles_i.
        mask_filled_tiles<<<num_blocks, NUM_THREADS>>>(
            stages[i].filled.get(),
            image_size_px / tile_size_px,
            stages[i].tiles.get(),
            count);

        // Do the actual tape evaluation, which is the expensive step
        eval_tiles_i<<<num_blocks, NUM_THREADS>>>(
            tape_data.get(),
            tape_index.get(),
            stages[i].filled.get(),
            image_size_px / tile_size_px,

            stages[i].tiles.get(),
            count,

            reinterpret_cast<Interval*>(values.get()));

        // Mark the total number of active tiles (from this stage) to 0
        cudaMemsetAsync(num_active_tiles.get(), 0, sizeof(int32_t));

        // Now that we have evaluated every tile at this level, we do one more
        // round of occlusion culling before accumulating tiles to render at
        // the next phase.
        mask_filled_tiles<<<num_blocks, NUM_THREADS>>>(
            stages[i].filled.get(),
            image_size_px / tile_size_px,
            stages[i].tiles.get(),
            count);

        // Count up active tiles, to figure out how much memory needs to be
        // allocated in the next stage.
        assign_next_nodes<<<num_blocks, NUM_THREADS>>>(
            stages[i].tiles.get(),
            count,
            num_active_tiles.get());

        // Count the number of active tiles, which have been accumulated
        // through repeated calls to assign_next_nodes
        int32_t active_tile_count;
        cudaMemcpy(&active_tile_count, num_active_tiles.get(), sizeof(int32_t),
                   cudaMemcpyDeviceToHost);
        if (i < 2) {
            active_tile_count *= 64;
        }

        // Make sure that the subtiles buffer has enough room
        // This wastes a small amount of data for the per-pixel evaluation,
        // where the `next` indexes aren't used, but it's relatively small.
        if (active_tile_count > stages[i + 1].tile_array_size) {
            stages[i + 1].tile_array_size = active_tile_count;
            stages[i + 1].tiles.reset(CUDA_MALLOC(TileNode, active_tile_count));
        }

        if (i < 2) {
            // Build the new tile list from active tiles in the previous list
            subdivide_active_tiles<<<num_blocks*64, NUM_THREADS>>>(
                stages[i].tiles.get(),
                count,
                image_size_px / tile_size_px,
                stages[i + 1].tiles.get());
        } else {
            // Special case for per-pixel evaluation, which
            // doesn't unpack every single pixel (since that would take up
            // 64x extra space).
            copy_active_tiles<<<num_blocks, NUM_THREADS>>>(
                stages[i].tiles.get(),
                count,
                image_size_px / tile_size_px,
                stages[i + 1].tiles.get());
        }

        {   // Copy filled tiles into the next level's image (expanding them
            // by 64x).  This is cleaner that accumulating all of the levels
            // in a single pass, and could (possibly?) help with skipping
            // fully occluded tiles.
            const unsigned next_tile_size = tile_size_px / 4;
            const uint32_t u = ((image_size_px / next_tile_size) / 32);
            copy_filled<<<dim3(u + 1, u + 1), dim3(32, 32)>>>(
                    stages[i].filled.get(),
                    stages[i + 1].filled.get(),
                    image_size_px / next_tile_size);
        }

        // Assign the next number of tiles to evaluate
        count = active_tile_count;
    }

    // Time to render individual pixels!
    num_blocks = (count + NUM_TILES - 1) / NUM_TILES;
    const size_t num_values = num_blocks * NUM_TILES * 32 * 3;
    if (values_size < num_values) {
        values.reset(CUDA_MALLOC(float2, num_values));
        values_size = num_values;
    }
    calculate_voxels<<<num_blocks, NUM_TILES * 32>>>(
        stages[3].tiles.get(),
        count,
        image_size_px / 4,
        mat,
        reinterpret_cast<float2*>(values.get()));
    eval_voxels_f<<<num_blocks, NUM_TILES * 32>>>(
        tape_data.get(),
        stages[3].filled.get(),
        image_size_px / 4,

        stages[3].tiles.get(),
        count,

        reinterpret_cast<float2*>(values.get()));

    {   // Then render normals into those pixels
        const uint32_t u = ((image_size_px + 15) / 16);
        eval_pixels_d<<<dim3(u, u), dim3(16, 16)>>>(
                tape_data.get(),
                stages[3].filled.get(),
                normals.get(),
                image_size_px,
                mat,
                stages[0].tiles.get(),
                stages[1].tiles.get(),
                stages[2].tiles.get());
    }
    CUDA_CHECK(cudaDeviceSynchronize());
}

} // namespace cuda
} // namespace libfive
