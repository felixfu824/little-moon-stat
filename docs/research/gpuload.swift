// 15-second GPU ALU load via a Metal compute kernel.
import Metal
import Foundation

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
let end = Date().addingTimeInterval(15)
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
print("gpu load done")
