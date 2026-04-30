#if canImport(COpenBLAS)
import COpenBLAS
let A = [1.0, 2.0, 3.0, 4.0]
let B = [4.0, 3.0, 2.0, 1.0]
var C = [0.0, 0.0, 0.0, 0.0]
cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2, 1, A, 2, B, 2, 0, &C, 2)
print("AB=\(C)")
#else
print("Hello world")
#endif