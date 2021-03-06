#import "GPUImageHarrisCornerDetectionFilter.h"
#import "GPUImageFilter.h"
#import "GPUImageGaussianBlurFilter.h"
#import "GPUImageXYDerivativeFilter.h"
#import "GPUImageGrayscaleFilter.h"
#import "GPUImageFastBlurFilter.h"
#import "GPUImageNonMaximumSuppressionFilter.h"

@interface GPUImageHarrisCornerDetectionFilter()

- (void)extractCornerLocationsFromImage;

@end

// This is the Harris corner detector, as described in 
// C. Harris and M. Stephens. A Combined Corner and Edge Detector. Proc. Alvey Vision Conf., Univ. Manchester, pp. 147-151, 1988.

@implementation GPUImageHarrisCornerDetectionFilter

NSString *const kGPUImageHarrisCornerDetectionFragmentShaderString = SHADER_STRING
( 
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 uniform lowp float sensitivity;
 
 const mediump float harrisConstant = 0.04;
 
 void main()
 {
     mediump vec3 derivativeElements = texture2D(inputImageTexture, textureCoordinate).rgb;
     
     mediump float derivativeSum = derivativeElements.x + derivativeElements.y;
     
     // This is the Noble variant on the Harris detector, from 
     // Alison Noble, "Descriptions of Image Surfaces", PhD thesis, Department of Engineering Science, Oxford University 1989, p45.  
     // R = (Ix^2 * Iy^2 - Ixy * Ixy) / (Ix^2 + Iy^2)
     mediump float zElement = (derivativeElements.z * 2.0) - 1.0;
//     mediump float harrisIntensity = (derivativeElements.x * derivativeElements.y - (derivativeElements.z * derivativeElements.z)) / (derivativeSum);
     mediump float harrisIntensity = (derivativeElements.x * derivativeElements.y - (zElement * zElement)) / (derivativeSum);

     // Original Harris detector
     // R = Ix^2 * Iy^2 - Ixy * Ixy - k * (Ix^2 + Iy^2)^2
//     highp float harrisIntensity = derivativeElements.x * derivativeElements.y - (derivativeElements.z * derivativeElements.z) - harrisConstant * derivativeSum * derivativeSum;
     
//     gl_FragColor = vec4(vec3(harrisIntensity * 7.0), 1.0);
     gl_FragColor = vec4(vec3(harrisIntensity * sensitivity), 1.0);
 }
);

NSString *const kGPUImageSimpleThresholdFragmentShaderString = SHADER_STRING
( 
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 uniform lowp float threshold;
 
 void main()
 {
     lowp float intensity = texture2D(inputImageTexture, textureCoordinate).r;

     lowp float thresholdValue = step(threshold, intensity);
     
     gl_FragColor = vec4(thresholdValue, 0.0, 0.0, 1.0);
 }
);

@synthesize blurSize;
@synthesize cornersDetectedBlock;
@synthesize sensitivity = _sensitivity;
@synthesize threshold = _threshold;
@synthesize intermediateImages = _intermediateImages;

#pragma mark -
#pragma mark Initialization and teardown

- (id)init;
{
    if (!(self = [self initWithCornerDetectionFragmentShader:kGPUImageHarrisCornerDetectionFragmentShaderString]))
    {
        return nil;
    }
    
    return self;
}

- (id)initWithCornerDetectionFragmentShader:(NSString *)cornerDetectionFragmentShader;
{
    if (!(self = [super init]))
    {
		return nil;
    }

#ifdef DEBUGFEATUREDETECTION
    _intermediateImages = [[NSMutableArray alloc] init];
#endif
    
    // First pass: reduce to luminance and take the derivative of the luminance texture
    derivativeFilter = [[GPUImageXYDerivativeFilter alloc] init];
//    derivativeFilter.imageWidthFactor = 256.0;
//    derivativeFilter.imageHeightFactor = 256.0;
    [self addFilter:derivativeFilter];

#ifdef DEBUGFEATUREDETECTION
    __unsafe_unretained NSMutableArray *weakIntermediateImages = _intermediateImages;
    __unsafe_unretained GPUImageFilter *weakFilter = derivativeFilter;
    [derivativeFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *filter){
        UIImage *intermediateImage = [weakFilter imageFromCurrentlyProcessedOutput];
        [weakIntermediateImages addObject:intermediateImage];
    }];
#endif

    // Second pass: blur the derivative
//    blurFilter = [[GPUImageGaussianBlurFilter alloc] init];
    blurFilter = [[GPUImageFastBlurFilter alloc] init];
    [self addFilter:blurFilter];
    
#ifdef DEBUGFEATUREDETECTION
    weakFilter = blurFilter;
    [blurFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *filter){
        UIImage *intermediateImage = [weakFilter imageFromCurrentlyProcessedOutput];
        [weakIntermediateImages addObject:intermediateImage];
    }];
#endif
    
    // Third pass: apply the Harris corner detection calculation
    harrisCornerDetectionFilter = [[GPUImageFilter alloc] initWithFragmentShaderFromString:cornerDetectionFragmentShader];
    [self addFilter:harrisCornerDetectionFilter];

#ifdef DEBUGFEATUREDETECTION
    weakFilter = harrisCornerDetectionFilter;
    [harrisCornerDetectionFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *filter){
        UIImage *intermediateImage = [weakFilter imageFromCurrentlyProcessedOutput];
        [weakIntermediateImages addObject:intermediateImage];
    }];
#endif

    // Fourth pass: apply non-maximum suppression to find the local maxima
    nonMaximumSuppressionFilter = [[GPUImageNonMaximumSuppressionFilter alloc] init];
    [self addFilter:nonMaximumSuppressionFilter];

#ifdef DEBUGFEATUREDETECTION
    weakFilter = nonMaximumSuppressionFilter;
    [nonMaximumSuppressionFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *filter){
        UIImage *intermediateImage = [weakFilter imageFromCurrentlyProcessedOutput];
        [weakIntermediateImages addObject:intermediateImage];
    }];
#endif

    // Fifth pass: threshold the result
    simpleThresholdFilter = [[GPUImageFilter alloc] initWithFragmentShaderFromString:kGPUImageSimpleThresholdFragmentShaderString];
    [self addFilter:simpleThresholdFilter];

#ifdef DEBUGFEATUREDETECTION
    weakFilter = simpleThresholdFilter;
    [simpleThresholdFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *filter){
        UIImage *intermediateImage = [weakFilter imageFromCurrentlyProcessedOutput];
        [weakIntermediateImages addObject:intermediateImage];
    }];
#endif

    __unsafe_unretained GPUImageHarrisCornerDetectionFilter *weakSelf = self;
    [simpleThresholdFilter setFrameProcessingCompletionBlock:^(GPUImageOutput *filter) {
        [weakSelf extractCornerLocationsFromImage];
    }];
    
    [derivativeFilter addTarget:blurFilter];    
    [blurFilter addTarget:harrisCornerDetectionFilter];
    [harrisCornerDetectionFilter addTarget:nonMaximumSuppressionFilter];
    [nonMaximumSuppressionFilter addTarget:simpleThresholdFilter];
    
    self.initialFilters = [NSArray arrayWithObjects:derivativeFilter, nil];
//    self.terminalFilter = harrisCornerDetectionFilter;
//    self.terminalFilter = nonMaximumSuppressionFilter;
    self.terminalFilter = simpleThresholdFilter;
    
    self.blurSize = 1.0;
    self.sensitivity = 5.0;
    self.threshold = 0.20;
    
    return self;
}
     
- (void)dealloc;
{
    free(rawImagePixels);    
}

#pragma mark -
#pragma mark Corner extraction

- (void)extractCornerLocationsFromImage;
{

    NSUInteger numberOfCorners = 0;
    CGSize imageSize = simpleThresholdFilter.outputFrameSize;
    
    if (rawImagePixels == NULL)
    {
        rawImagePixels = (GLubyte *)malloc(imageSize.width * imageSize.height * 4);
    }
    
    cornersArray = calloc(512 * 2, sizeof(GLfloat));
    
    glReadPixels(0, 0, (int)imageSize.width, (int)imageSize.height, GL_RGBA, GL_UNSIGNED_BYTE, rawImagePixels);

    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();

    for (unsigned int yCoordinate = 0; yCoordinate < imageSize.height; yCoordinate++)
    {
        for (unsigned int xCoordinate = 0; xCoordinate < imageSize.width; xCoordinate++)
        {            
            GLubyte redByte = rawImagePixels[(yCoordinate * (int)imageSize.width + xCoordinate) * 4];
            if (redByte > 100)
            {
                cornersArray[numberOfCorners * 2] = (CGFloat)xCoordinate / imageSize.width;
                cornersArray[numberOfCorners * 2 + 1] = (CGFloat)(yCoordinate + 1) / imageSize.height;
                numberOfCorners++;
                if (numberOfCorners > 511)
                {
                    numberOfCorners = 511;
                }
            }
        }
    }
    
    CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
    NSLog(@"Processing time : %f ms", 1000.0 * currentFrameTime);

    if (cornersDetectedBlock != NULL)
    {
        cornersDetectedBlock(cornersArray, numberOfCorners);
    }
    
    free(cornersArray);
}

#pragma mark -
#pragma mark Accessors

- (void)setBlurSize:(CGFloat)newValue;
{
    blurFilter.blurSize = newValue;
}

- (CGFloat)blurSize;
{
    return blurFilter.blurSize;
}

- (void)setSensitivity:(CGFloat)newValue;
{
    _sensitivity = newValue;
    [harrisCornerDetectionFilter setFloat:newValue forUniform:@"sensitivity"];
}

- (void)setThreshold:(CGFloat)newValue;
{
    _threshold = newValue;
    [simpleThresholdFilter setFloat:newValue forUniform:@"threshold"];
}

@end
