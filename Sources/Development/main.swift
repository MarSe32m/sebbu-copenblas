#if canImport(COpenBLAS)
import COpenBLAS
// cblas test
var A = [1.0, 2.0, 3.0, 4.0]
let B = [4.0, 3.0, 2.0, 1.0]
var C = [0.0, 0.0, 0.0, 0.0]
cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2, 1, A, 2, B, 2, 0, &C, 2)
print("AB=\(C)")

// LAPACKE test
A = [3.0, 1.0, 1.0, 2.0]
var b = [9.0, 8.0]
var ipiv: [CInt] = [0, 0]
let info = LAPACKE_dgesv(LAPACK_ROW_MAJOR, 2, 1, &A, 2, &ipiv, &b, 1)
print("info=\(info), x=(\(b[0]),\(b[1]))")
#else
print("Hello world")
#endif