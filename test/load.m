// Loads a .metallib on the system GPU and builds render and compute pipelines from it.
#import <Metal/Metal.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s file.metallib\n", argv[0]);
            return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
        if (!lib) {
            fprintf(stderr, "load failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        MTLRenderPipelineDescriptor *render = [MTLRenderPipelineDescriptor new];
        render.vertexFunction = [lib newFunctionWithName:@"testVertex"];
        render.fragmentFunction = [lib newFunctionWithName:@"testFragment"];
        render.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (![device newRenderPipelineStateWithDescriptor:render error:&error]) {
            fprintf(stderr, "render pipeline failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        id<MTLFunction> kernel = [lib newFunctionWithName:@"testKernel"];
        if (!kernel || ![device newComputePipelineStateWithFunction:kernel error:&error]) {
            fprintf(stderr, "compute pipeline failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        printf("ok: %s loaded %lu functions, render + compute pipelines built\n",
               device.name.UTF8String, (unsigned long)lib.functionNames.count);
    }
    return 0;
}
