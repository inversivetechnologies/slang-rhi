
float StencilSquare(float2 p)
{
    float w = float(p.x > 0 && p.x < 1);
    float h = float(p.y > 0 && p.y < 1);
    return min(w, h);
}

float StencilCircle(float2 p)
{
    return float(length(p) <= 1);
}
