// Bitonic sort of (key, value) pairs on the GPU, ascending by key, in place.
//
// The element count must be a power of two, at least 1024; pad with keys that sort last.
// A full sort of n elements is a sequence of dispatches, each over n / 2 threads (one per
// compared pair):
//
//   sortBlocksMain with sortStage = 0       sorts every block of 1024 elements
//   for k = 2048, 4096, ..., n:
//     sortStepMain with sortK = k, sortJ = j     for j = k/2, k/4, ..., 1024
//     sortBlocksMain with sortStage = k          finishes j = 512 .. 1 for this k
//
// Steps that compare elements less than 1024 apart stay within one block, so
// sortBlocksMain does all of them in group shared memory in a single dispatch; only the
// longer-range steps need a dispatch each. For 2^21 elements that is 78 dispatches instead
// of 231.
//
// Only a prefix may hold keys: sortActive[0] says how many (the rest are ignored, and
// never read). The sort then works on the smallest power of two that holds them (at
// least 1024), which the caller pads with keys that sort last; threads past it return
// at once. Once that prefix is sorted, the longer steps would leave it as it is, since
// everything after it sorts last anyway -- so the dispatches can stay the same for any
// count. For a full sort, sortActive[0] is the element count.

RWStructuredBuffer<float> sortKeys;
RWStructuredBuffer<uint> sortValues;
StructuredBuffer<uint> sortActive;

// The power of two the sort works on.
uint activeSize()
{
    uint count = sortActive[0];
    return count <= 1024 ? 1024 : 1u << (firstbithigh(count - 1) + 1);
}

uniform uint sortK;     // sortStepMain: the size of the bitonic sequences being merged
uniform uint sortJ;     // sortStepMain: the distance between compared elements
uniform uint sortStage; // sortBlocksMain: 0 to sort each block, else the k to finish

// The first element of compare pair `pair` for distance j (the second is j further).
uint pairStart(uint pair, uint j)
{
    return 2 * j * (pair / j) + (pair % j);
}

// Whether a pair must be swapped. (Written without `ascending ? a > b : a < b`, which
// D3D11's fxc fails to compile inside these kernels: "internal error: flattened side
// effect".)
bool outOfOrder(float a, float b, bool ascending)
{
    return a != b && (a > b) == ascending;
}

[shader("compute")]
[numthreads(256, 1, 1)]
void sortStepMain(uint3 tid: SV_DispatchThreadID)
{
    uint i = pairStart(tid.x, sortJ);
    uint l = i + sortJ;
    if (l >= activeSize())
    {
        return;
    }
    bool ascending = (i & sortK) == 0;
    float a = sortKeys[i];
    float b = sortKeys[l];
    if (outOfOrder(a, b, ascending))
    {
        sortKeys[i] = b;
        sortKeys[l] = a;
        uint value = sortValues[i];
        sortValues[i] = sortValues[l];
        sortValues[l] = value;
    }
}

static const uint kBlockSize = 1024;
groupshared float blockKeys[kBlockSize];
groupshared uint blockValues[kBlockSize];

void blockStep(uint pair, uint blockStart, uint k, uint j)
{
    uint i = pairStart(pair, j);
    uint l = i + j;
    bool ascending = ((blockStart + i) & k) == 0;
    float a = blockKeys[i];
    float b = blockKeys[l];
    if (outOfOrder(a, b, ascending))
    {
        blockKeys[i] = b;
        blockKeys[l] = a;
        uint value = blockValues[i];
        blockValues[i] = blockValues[l];
        blockValues[l] = value;
    }
}

// One group per block of 1024 elements, one thread per compared pair.
[shader("compute")]
[numthreads(512, 1, 1)]
void sortBlocksMain(uint3 groupId: SV_GroupID, uint3 threadId: SV_GroupThreadID)
{
    uint t = threadId.x;
    uint blockStart = groupId.x * kBlockSize;
    if (blockStart >= activeSize())
    {
        return; // the whole group: blocks are 1024, and so a multiple of the size
    }
    blockKeys[t] = sortKeys[blockStart + t];
    blockKeys[t + 512] = sortKeys[blockStart + t + 512];
    blockValues[t] = sortValues[blockStart + t];
    blockValues[t + 512] = sortValues[blockStart + t + 512];
    GroupMemoryBarrierWithGroupSync();

    if (sortStage == 0)
    {
        for (uint k = 2; k <= kBlockSize; k <<= 1)
        {
            for (uint j = k >> 1; j > 0; j >>= 1)
            {
                blockStep(t, blockStart, k, j);
                GroupMemoryBarrierWithGroupSync();
            }
        }
    }
    else
    {
        for (uint j = kBlockSize >> 1; j > 0; j >>= 1)
        {
            blockStep(t, blockStart, sortStage, j);
            GroupMemoryBarrierWithGroupSync();
        }
    }

    sortKeys[blockStart + t] = blockKeys[t];
    sortKeys[blockStart + t + 512] = blockKeys[t + 512];
    sortValues[blockStart + t] = blockValues[t];
    sortValues[blockStart + t + 512] = blockValues[t + 512];
}
