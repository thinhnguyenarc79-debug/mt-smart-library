class Vector(list):
    def __init__(self, c):
        super().__init__([float(x) for x in c])
class Matrix:
    def __init__(self, s=1.0):
        self.s = s
    def __matmul__(self, v):
        return Vector([x * self.s for x in v])
    def copy(self):
        return Matrix(self.s)
