#include "CLProjection.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static const double identity[16] = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1
};

int main(void) {
    CLProjectedRect rect;
    const double centeredPosition[3] = {0, 0, 0};
    const double dimensions[3] = {1, 1, 1};
    assert(CLProjectAABB(identity, centeredPosition, dimensions, -1, 1,
                         0, 0, 1000, 500, &rect));
    assert(fabs(rect.x - 250) < 1e-9);
    assert(fabs(rect.y - 0) < 1e-9);
    assert(fabs(rect.width - 500) < 1e-9);
    assert(fabs(rect.height - 250) < 1e-9);

    const double outsidePosition[3] = {3, 0, 0};
    assert(!CLProjectAABB(identity, outsidePosition, dimensions, -1, 1,
                          0, 0, 1000, 500, &rect));
    assert(!CLProjectAABB(identity, centeredPosition, dimensions, -1, 1,
                          0, 0, 0, 500, &rect));

    const double badDimensions[3] = {1, 0, 1};
    assert(!CLProjectAABB(identity, centeredPosition, badDimensions, -1, 1,
                          0, 0, 1000, 500, &rect));

    double behindMatrix[16] = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 1, 0
    };
    const double behindPosition[3] = {0, 0, -2};
    assert(!CLProjectAABB(behindMatrix, behindPosition, dimensions, -1, 1,
                          0, 0, 1000, 500, &rect));

    double invalidMatrix[16];
    for (int i = 0; i < 16; i++) invalidMatrix[i] = identity[i];
    invalidMatrix[0] = NAN;
    assert(!CLProjectAABB(invalidMatrix, centeredPosition, dimensions, -1, 1,
                          0, 0, 1000, 500, &rect));
    puts("projection tests passed");
    return 0;
}
