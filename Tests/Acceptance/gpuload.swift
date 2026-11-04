// Bounded Metal ALU load: gpuload <seconds ≤ 30>. Based on docs/research/gpuload.swift.
import Metal
import Foundation
let secs = min(30, max(1, Double(CommandLine.arguments.dropFirst().first ?? "15") ?? 15))
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id) * 0.0001;
    for (int i = 0; i < 20000; i++) { x = fma(x, 1.000001, 0.0000001); x = sin(x) + cos(x); }
    out[id] = x;
}
"""
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "burn")!)
let q = dev.makeCommandQueue()!
let n = 1 << 20
let buf = dev.makeBuffer(length: n * 4, options: .storageModePrivate)!
let end = Date().addingTimeInterval(secs)
while Date() < end {
    let cb = q.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}
