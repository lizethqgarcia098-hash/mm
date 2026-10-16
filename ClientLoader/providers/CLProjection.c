#include "CLProjection.h"
#include <float.h>
#include <math.h>

static double CLTransform(const double matrix[16], int row,
                          double x, double y, double z) {
    return matrix[row] * x + matrix[4 + row] * y +
        matrix[8 + row] * z + matrix[12 + row];
}

int CLProjectAABB(const double matrix[16],
                  const double position[3],
                  const double dimensions[3],
                  double clipDepthMinimum,
                  double clipDepthMaximum,
                  double viewportX,
                  double viewportY,
                  double viewportWidth,
                  double viewportHeight,
                  CLProjectedRect *result) {
    if (!matrix || !position || !dimensions || !result ||
        !isfinite(clipDepthMinimum) || !isfinite(clipDepthMaximum) ||
        clipDepthMinimum >= clipDepthMaximum ||
        !isfinite(viewportX) || !isfinite(viewportY) ||
        !isfinite(viewportWidth) || !isfinite(viewportHeight) ||
        viewportWidth <= 0 || viewportHeight <= 0) return 0;

    for (int i = 0; i < 16; i++) if (!isfinite(matrix[i])) return 0;
    for (int i = 0; i < 3; i++) {
        if (!isfinite(position[i]) || !isfinite(dimensions[i]) || dimensions[i] <= 0) {
            return 0;
        }
    }

    double minX = DBL_MAX, minY = DBL_MAX;
    double maxX = -DBL_MAX, maxY = -DBL_MAX;
    for (unsigned corner = 0; corner < 8; corner++) {
        double x = position[0] + ((corner & 1) ? dimensions[0] * 0.5 : -dimensions[0] * 0.5);
        double y = position[1] + ((corner & 2) ? dimensions[1] : 0.0);
        double z = position[2] + ((corner & 4) ? dimensions[2] * 0.5 : -dimensions[2] * 0.5);
        double clipX = CLTransform(matrix, 0, x, y, z);
        double clipY = CLTransform(matrix, 1, x, y, z);
        double clipZ = CLTransform(matrix, 2, x, y, z);
        double clipW = CLTransform(matrix, 3, x, y, z);
        if (!isfinite(clipW) || clipW <= 1e-5) return 0;

        double ndcX = clipX / clipW;
        double ndcY = clipY / clipW;
        double ndcZ = clipZ / clipW;
        if (!isfinite(ndcX) || !isfinite(ndcY) || !isfinite(ndcZ) ||
            ndcZ < clipDepthMinimum || ndcZ > clipDepthMaximum) return 0;
        if (ndcX < minX) minX = ndcX;
        if (ndcX > maxX) maxX = ndcX;
        if (ndcY < minY) minY = ndcY;
        if (ndcY > maxY) maxY = ndcY;
    }

    if (maxX < -1 || minX > 1 || maxY < -1 || minY > 1) return 0;
    double left = viewportX + (fmax(minX, -1) + 1) * 0.5 * viewportWidth;
    double right = viewportX + (fmin(maxX, 1) + 1) * 0.5 * viewportWidth;
    double top = viewportY + (1 - fmin(maxY, 1)) * 0.5 * viewportHeight;
    double bottom = viewportY + (1 - fmax(minY, -1)) * 0.5 * viewportHeight;
    if (!isfinite(left) || !isfinite(right) || !isfinite(top) || !isfinite(bottom) ||
        right <= left || bottom <= top) return 0;

    result->x = left;
    result->y = top;
    result->width = right - left;
    result->height = bottom - top;
    return 1;
}
