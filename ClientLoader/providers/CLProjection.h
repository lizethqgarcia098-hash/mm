#ifndef CL_PROJECTION_H
#define CL_PROJECTION_H

typedef struct {
    double x;
    double y;
    double width;
    double height;
} CLProjectedRect;

int CLProjectAABB(const double columnMajorMatrix[16],
                  const double position[3],
                  const double dimensions[3],
                  double clipDepthMinimum,
                  double clipDepthMaximum,
                  double viewportX,
                  double viewportY,
                  double viewportWidth,
                  double viewportHeight,
                  CLProjectedRect *result);

#endif
