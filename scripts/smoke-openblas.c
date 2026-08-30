#include <cblas.h>
#include <lapacke.h>

#include <math.h>
#include <stdio.h>

static int nearly_equal(double lhs, double rhs) {
    return fabs(lhs - rhs) < 1.0e-12;
}

int main(void) {
    const double a[4] = {1.0, 2.0, 3.0, 4.0};
    const double b[4] = {5.0, 6.0, 7.0, 8.0};
    double c[4] = {0.0, 0.0, 0.0, 0.0};

    cblas_dgemm(
        CblasRowMajor,
        CblasNoTrans,
        CblasNoTrans,
        2,
        2,
        2,
        1.0,
        a,
        2,
        b,
        2,
        0.0,
        c,
        2
    );
    if (!nearly_equal(c[0], 19.0) || !nearly_equal(c[1], 22.0) ||
        !nearly_equal(c[2], 43.0) || !nearly_equal(c[3], 50.0)) {
        fputs("CBLAS smoke test failed.\n", stderr);
        return 1;
    }

    double system_matrix[4] = {3.0, 1.0, 1.0, 2.0};
    double right_hand_side[2] = {9.0, 8.0};
    lapack_int pivots[2];
    const lapack_int info = LAPACKE_dgesv(
        LAPACK_ROW_MAJOR,
        2,
        1,
        system_matrix,
        2,
        pivots,
        right_hand_side,
        1
    );
    if (info != 0 || !nearly_equal(right_hand_side[0], 2.0) ||
        !nearly_equal(right_hand_side[1], 3.0)) {
        fprintf(stderr, "LAPACKE smoke test failed with info=%d.\n", (int)info);
        return 1;
    }

    puts("OpenBLAS CBLAS/LAPACKE smoke test passed.");
    return 0;
}
