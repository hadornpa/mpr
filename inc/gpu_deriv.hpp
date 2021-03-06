/*
Reference implementation for
"Massively Parallel Rendering of Complex Closed-Form Implicit Surfaces"
(SIGGRAPH 2020)

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this file,
You can obtain one at http://mozilla.org/MPL/2.0/.

Copyright (C) 2019-2020  Matt Keeter
*/
#pragma once

#include <math_constants.h>

namespace mpr {

struct Deriv {
    __device__ inline Deriv() : v(make_float4(0.0f, 0.0f, 0.0f, 0.0f)) {}
    __device__ inline explicit Deriv(float f) : v(make_float4(0.0f, 0.0f, 0.0f, f)) {}
    __device__ inline Deriv(float v, float dx, float dy, float dz)
        : v(make_float4(dx, dy, dz, v)) {}
    __device__ inline float value() const { return v.w; }
    __device__ inline float dx() const { return v.x; }
    __device__ inline float dy() const { return v.y; }
    __device__ inline float dz() const { return v.z; }
    float4 v;
};

#ifdef __CUDACC__
__device__ inline float value(const Deriv& a) {
    return a.value();
}

__device__ inline float value(const float& a) {
    return a;
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv operator-(const Deriv& a) {
    return {-a.value(), -a.dx(), -a.dy(), -a.dz()};
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv operator+(const Deriv& a, const Deriv& b) {
    return {a.value() + b.value(),
            a.dx() + b.dx(),
            a.dy() + b.dy(),
            a.dz() + b.dz()};
}

__device__ inline Deriv operator+(const Deriv& a, const float& b) {
    return {a.value() + b, a.dx(), a.dy(), a.dz()};
}

__device__ inline Deriv operator+(const float& b, const Deriv& a) {
    return a + b;
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv operator*(const Deriv& a, const Deriv& b) {
    return {a.value() * b.value(),
            a.dx() * b.value() + b.dx() * a.value(),
            a.dy() * b.value() + b.dy() * a.value(),
            a.dz() * b.value() + b.dz() * a.value()};
}

__device__ inline Deriv operator*(const Deriv& a, const float& b) {
    return {a.value() * b,
            a.dx() * b,
            a.dy() * b,
            a.dz() * b};
}

__device__ inline Deriv operator*(const float& a, const Deriv& b) {
    return b * a;
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv operator/(const Deriv& a, const Deriv& b) {
    const float d = powf(b.value(), 2);
    return {a.value() / b.value(),
            (b.value() * a.dx() - a.value() * b.dx()) / d,
            (b.value() * a.dy() - a.value() * b.dy()) / d,
            (b.value() * a.dz() - a.value() * b.dz()) / d};
}

__device__ inline Deriv operator/(const Deriv& a, const float& b) {
    return {a.value() / b, a.dx() / b, a.dy() / b, a.dz() / b};
}

__device__ inline Deriv operator/(const float& a, const Deriv& b) {
    const float d = powf(b.value(), 2);
    return {a / b.value(),
            -a * b.dx() / d,
            -a * b.dy() / d,
            -a * b.dz() / d};
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv min(const Deriv& a, const Deriv& b) {
    return (a.value() < b.value()) ? a : b;
}

__device__ inline Deriv min(const Deriv& a, const float& b) {
    return (a.value() < b) ? a : Deriv(b);
}

__device__ inline Deriv min(const float& a, const Deriv& b) {
    return min(b, a);
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv max(const Deriv& a, const Deriv& b) {
    return (a.value() >= b.value()) ? a : b;
}

__device__ inline Deriv max(const Deriv& a, const float& b) {
    return (a.value() >= b) ? a : Deriv(b);
}

__device__ inline Deriv max(const float& a, const Deriv& b) {
    return max(b, a);
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv square(const Deriv& a) {
    return {a.value() * a.value(),
            a.dx() * a.value() * 2,
            a.dy() * a.value() * 2,
            a.dz() * a.value() * 2};
}

__device__ inline Deriv abs(const Deriv& a) {
    if (a.value() < 0.0f) {
        return -a;
    } else {
        return a;
    }
}

////////////////////////////////////////////////////////////////////////////////

__device__ inline Deriv operator-(const Deriv& a, const Deriv& b) {
    return {a.value() - b.value(),
            a.dx() - b.dx(),
            a.dy() - b.dy(),
            a.dz() - b.dz()};
}

__device__ inline Deriv operator-(const Deriv& a, const float& b) {
    return {a.value() - b, a.dx(), a.dy(), a.dz()};
}

__device__ inline Deriv operator-(const float& a, const Deriv& b) {
    return {a - b.value(), -b.dx(), -b.dy(), -b.dz()};
}

__device__ inline Deriv sqrt(const Deriv& a) {
    const float d = (2 * sqrtf(a.value()));
    return {sqrtf(a.value()), a.dx() / d, a.dy() / d, a.dz() / d};
}

__device__ inline Deriv atan(const Deriv& a) {
    const float d = (a.value() * a.value() + 1);
    return {atanf(a.value()), a.dx() / d, a.dy() / d, a.dz() / d};
}

__device__ inline Deriv acos(const Deriv& a) {
    const float d = -sqrtf(1 - a.value() * a.value());
    return {acosf(a.value()), a.dx() / d, a.dy() / d, a.dz() / d};
}

__device__ inline Deriv asin(const Deriv& a) {
    const float d = sqrtf(1 - a.value() * a.value());
    return {asinf(a.value()), a.dx() / d, a.dy() / d, a.dz() / d};
}

__device__ inline Deriv exp(const Deriv& a) {
    const float v = expf(a.value());
    return {v, v * a.dx(), v * a.dy(), v * a.dz()};
}

__device__ inline Deriv cos(const Deriv& a) {
    const float s = -sinf(a.value());
    return {cosf(a.value()), s * a.dx(), s * a.dy(), s * a.dz()};
}

__device__ inline Deriv sin(const Deriv& a) {
    const float c = cosf(a.value());
    return {sinf(a.value()), c * a.dx(), c * a.dy(), c * a.dz()};
}

__device__ inline Deriv log(const Deriv& a) {
    const float v = a.value();
    return {logf(v), a.dx() / v, a.dy() / v, a.dz() / v};
}
#endif

}   // namespace mpr
