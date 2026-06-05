#include "calc.h"
#include <cassert>

int main() {
    assert(add(2, 3) == 5);
    assert(clamp(10, 0, 5) == 5);
    return 0;
}
