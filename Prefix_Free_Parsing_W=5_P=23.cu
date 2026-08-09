
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <thrust/iterator/discard_iterator.h>

#include <stdio.h>
#include <algorithm>
#include <chrono>
#include <assert.h>
#include <utility>
#include <thrust/scan.h>
#include <thrust/sort.h>
#include <thrust/execution_policy.h>
#include <thrust/device_vector.h>
#include <stdint.h> 
#include <cub/cub.cuh>

#define MAX_THREADS_PER_BLOCK 512
#define MAX_SHARED_MEM_PER_BLOCK 2048
#define Elements_Per_Block 4
#define P 23
#define W 5
#define D_Word_Length_Cap_Mult_Constant 3.5


using namespace std;

int n;
int n_enlarged;
int num_blocks_n;
int num_blocks_n_enlarged;
int num_blocks_N;
int size_D;
int num_blocks_size_D;
int size_D_Enlarged;
int num_blocks_size_D_Enlarged;
int size_D_Enlarged_without_duplicates;
int num_blocks_size_D_Enlarged_without_duplicates;
int size_S;
int num_blocks_size_S;
int size_Suffixes_Without_Same_Preeceding_Char;
int num_blocks_size_Suffixes_Without_Same_Preeceding_Char;

unsigned char* Dev_Input;
unsigned char* input;

unsigned char* Dev_Output;
unsigned char* output;

int* Auxiliar1;
int* Auxiliar2;
int* D_Ends;
int* D_Enlarged_Indexes;
int* D_Duplicate_Mapping;
int* D;
int* D_Mem1;
int* D_Enlarged_Prefix_Sum;
int* Suffixes_Without_Same_Preeceding_Char;

int* S_L;
int* S_Interval_Length;
int* S_Length_Suffix;

size_t   SegmentedSort_bytes = 0;
void* SegmentedSort_Temp_Storage;

unsigned char* Letter_Back_Transform_Dev;
int size_alphabet;
int cnt_word_length;
int D_Word_Length_Cap;
int D_Sort_Rounds;

__global__ void Init_Vector(unsigned char* Arr) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;

    Arr[thread_id] = 0;

}

__global__ void MarkAlphabet(
    const unsigned char* input,
    int n,
    unsigned char* Letter_Transform_Dev)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i < n)
        Letter_Transform_Dev[input[i]] = 1;
}

__global__ void Compute_Transform(unsigned char* Letter_Transform_Dev, unsigned char* Letter_Back_Transform_Dev, int* Res)
{
    int  size_alphabet = 2;
    for (int i = 0; i < 256; i++) {
        if (Letter_Transform_Dev[i]) {
            if (size_alphabet == 255)
                printf("\n The alphabet of the text is larger then 253. This is not allowed.");
            assert(size_alphabet < 255);
            Letter_Transform_Dev[i] = size_alphabet;
            Letter_Back_Transform_Dev[size_alphabet] = i;
            size_alphabet++;
        }

    }
    Res[0] = size_alphabet;
}

__global__ void Transform_Input(
    unsigned char* input,
    int n,
    unsigned char* Letter_Transform_Dev)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    if (i < n)
        input[i] = Letter_Transform_Dev[input[i]];
}

void Remap_Letters() {

    unsigned char* Letter_Transform_Dev;
    int* Res;

    cudaMalloc((void**)&Letter_Transform_Dev, (256) * sizeof(unsigned char));
    cudaMalloc((void**)&Letter_Back_Transform_Dev, (256) * sizeof(unsigned char));
    cudaMalloc((void**)&Res, sizeof(int));

    Init_Vector << <1, 256 >> > (Letter_Transform_Dev);

    MarkAlphabet << <num_blocks_N, MAX_THREADS_PER_BLOCK >> > (Dev_Input, n, Letter_Transform_Dev);

    Compute_Transform << <1, 1 >> > (Letter_Transform_Dev, Letter_Back_Transform_Dev, Res);

    cudaMemcpy(&size_alphabet, Res, sizeof(int), cudaMemcpyDeviceToHost);

    Transform_Input << <num_blocks_N, MAX_THREADS_PER_BLOCK >> > (Dev_Input, n, Letter_Transform_Dev);

    cnt_word_length = 0;
    unsigned int div = UINT32_MAX;
    while (div > 0) {
        div /= size_alphabet;
        cnt_word_length++;
    }

    if ((size_alphabet & (size_alphabet - 1)) != 0) {
        cnt_word_length--;
    }

    D_Word_Length_Cap = cnt_word_length * ((((int)(D_Word_Length_Cap_Mult_Constant * (W + P))) + cnt_word_length - 1) / cnt_word_length);
    D_Sort_Rounds = (D_Word_Length_Cap / cnt_word_length) - 1;

    cudaFree(Letter_Transform_Dev);
    cudaFree(Res);
}


void Scan_input() {

    //FILE* f = fopen("C:/Users/maxim/source/repos/Main/Debug/input.txt", "r");
    FILE* f = fopen("input.txt", "r");

    fscanf(f, "%d", &n);

    input = new unsigned char[n + 1 + W];
    output = new unsigned char[n + 1];

    memset(output, 255, n);
    output[n] = '\0';

    
    int val;
    for (int i = 0; i < n; i++) {
        fscanf(f, "%d", &val);
        input[i] = val;
    }
    

    //fscanf(f, "%s", input);

    for (int i = 0; i < W; i++)
        input[n + i] = 1;
    input[n + W] = '\0';
    n_enlarged = n + W;


}




int smallest_two_potenz_larger_than_k(int k) {
    int temp = 1;

    while (temp < k) {
        temp <<= 1;

    }

    return temp;
}





void Compute_Params() {
    num_blocks_n_enlarged = (n_enlarged - 1 + MAX_THREADS_PER_BLOCK * Elements_Per_Block) / (MAX_THREADS_PER_BLOCK * Elements_Per_Block);
    num_blocks_n = (n - 1 + MAX_THREADS_PER_BLOCK * Elements_Per_Block) / (MAX_THREADS_PER_BLOCK * Elements_Per_Block);
    num_blocks_N = (n - 1 + MAX_THREADS_PER_BLOCK) / MAX_THREADS_PER_BLOCK;
}

void Malloc_And_Copy_On_GPU() {
    cudaMalloc((void**)&Dev_Input, (n_enlarged + 1) * sizeof(unsigned char));
    cudaMemcpy(Dev_Input, input, (n_enlarged + 1) * sizeof(unsigned char), cudaMemcpyHostToDevice);

    cudaMalloc((void**)&Dev_Output, (n + 1) * sizeof(unsigned char));
    cudaMemcpy(Dev_Output, output, (n + 1) * sizeof(unsigned char), cudaMemcpyHostToDevice);


}

__device__ int minimum(int a, int b) {
    return ((a <= b) ? a : b);
}

__device__ __forceinline__ unsigned int pack_cnt_word_length(const unsigned char* data, int cnt_word_length, int size_alphabet) {
    unsigned int result = 0;
    unsigned int potenz = 1;
    for (int i = 0; i < cnt_word_length; i++) {
        result += ((unsigned int)data[i]) * potenz;
        potenz *= size_alphabet;
    }
    return result;
}

__device__ __forceinline__ unsigned long long pack_2_cnt_word_length(const unsigned char* data, int cnt_word_length, int size_alphabet) {
    unsigned long long result = 0ULL;
    unsigned long long potenz = 1;
    int r = cnt_word_length * 2;
    for (int i = 0; i < r; i++) {
        result += ((unsigned long long)data[i]) * potenz;
        potenz *= size_alphabet;
    }
    return result;
}

__device__ __forceinline__ unsigned long long pack8(const unsigned char* data) {
    unsigned long long result = 0;
#pragma unroll
    for (int i = 0; i < 8; i++) {
        result |= (unsigned long long)data[i] << ((7 - i) * 8);
    }
    return result;
}

__device__ __forceinline__ unsigned long long pack4(const unsigned char* data) {
    unsigned int result = 0;
#pragma unroll
    for (int i = 0; i < 4; i++) {
        result |= (unsigned int)data[i] << ((3 - i) * 8);
    }
    return result;
}



__global__ void Init_Vector(int* Arr, int n, int val) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < n) {
        Arr[thread_id] = val;
    }
}

__global__ void Init_Vector1(int* Arr, int n, int val, int offset) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < n) {
        Arr[(thread_id + offset)] = val;
    }
}

__global__ void Pointer_Jumping_S_Kernel2(int* Array1, int* Array2, int* S_Length_Suffix, int stride, int n) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < n) {
        int index = Array2[thread_id];
        if (S_Length_Suffix[thread_id] > stride)
            Array1[thread_id] = Array2[index];
        else
            Array1[thread_id] = index;

    }
}


__global__ void Pointer_Jumping_Kernel_Optimized(
    int* __restrict__ d_out,
    const int* __restrict__ d_in,
    int n,
    int stride
) {
    int thread_id = blockIdx.x * blockDim.x + threadIdx.x;

    if (thread_id < n) {
        int val = d_in[thread_id];
        int index = thread_id - stride;

        if (val == -1 && index >= 0) {
            d_out[thread_id] = d_in[index];
        }
        else {
            d_out[thread_id] = val;
        }
    }
}

void Pointer_Jumping(int* d_A, int* d_B, int size_cur) {
    const int num_blocks = (size_cur + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

    int* d_in = d_A;
    int* d_out = d_B;

    for (int stride = 1; stride < size_cur; stride <<= 1) {
        Pointer_Jumping_Kernel_Optimized << <num_blocks, MAX_THREADS_PER_BLOCK >> > (d_out, d_in, size_cur, stride);

        std::swap(d_in, d_out);
    }

    if (d_in != d_A) {
        cudaMemcpy(d_A, d_B, size_cur * sizeof(int), cudaMemcpyDeviceToDevice);
    }

}

__global__ void Compute_D1(unsigned char* Dev_Input, int* D_Block_Sum, int n) {
    __shared__ unsigned char Sub_String[MAX_THREADS_PER_BLOCK * Elements_Per_Block + W];
    __shared__ short Sum[MAX_THREADS_PER_BLOCK];
    unsigned char first_word_in_D[W];
    for (int i = 0; i < W; i++)
        first_word_in_D[i] = Dev_Input[i];
    int block_id = blockIdx.x;
    int thread_id = threadIdx.x;
    int l = MAX_THREADS_PER_BLOCK * Elements_Per_Block * block_id + thread_id;
    int r = l + W - 1;
    int local_sum = 0;
    for (int j = 0; j < Elements_Per_Block; j++) {
        Sub_String[thread_id + W - 1 + MAX_THREADS_PER_BLOCK * j] = ((r + MAX_THREADS_PER_BLOCK * j < n) ? Dev_Input[r + MAX_THREADS_PER_BLOCK * j] : 0);

    }
    if (thread_id < W - 1 && l < n)
        Sub_String[thread_id] = Dev_Input[l];

    __syncthreads();
    for (int j = 0; j < Elements_Per_Block && (r + MAX_THREADS_PER_BLOCK * j < n); j++) {
        int potenz_2_mod_P = 1;
        int res = 0;
        int l1 = thread_id + MAX_THREADS_PER_BLOCK * j;
        int r1 = l1 + W - 1;
        bool equal = true;
        for (int i = r1; i >= l1; i--) {

            equal = ((equal == true) ? Sub_String[i] == first_word_in_D[i - l1] : false);
            res = (res + potenz_2_mod_P * int(Sub_String[i])) % P;
            potenz_2_mod_P = (potenz_2_mod_P * 2) % P;
        }

        if ((res == 0 && (l > 0 || (l == 0 && l1 > 0))) || (equal && (l > 0 || (l == 0 && l1 > 0)))) {
            local_sum++;

        }
    }

    Sum[thread_id] = local_sum;
    for (int stride = MAX_THREADS_PER_BLOCK >> 1; stride > 0; stride >>= 1) {
        __syncthreads();

        if (thread_id < stride) {
            Sum[thread_id] = Sum[thread_id] + Sum[thread_id + stride];

        }
    }

    if (thread_id == 0)
        D_Block_Sum[block_id] = Sum[0];




}


__global__ void Compute_D2(unsigned char* Dev_Input, int* D_Blocks_Prefix_Sum, int* D_Ends, int n) {
    __shared__ unsigned char Sub_String[MAX_THREADS_PER_BLOCK * Elements_Per_Block + W];
    __shared__ short Prefix_Sum[MAX_THREADS_PER_BLOCK * Elements_Per_Block];
    short Saved_Sums[Elements_Per_Block];
    unsigned char first_word_in_D[W];
    for (int i = 0; i < W; i++)
        first_word_in_D[i] = Dev_Input[i];
    int block_id = blockIdx.x;
    int thread_id = threadIdx.x;
    int l = MAX_THREADS_PER_BLOCK * Elements_Per_Block * block_id + thread_id;
    int r = l + W - 1;
    int offset = ((block_id - 1 >= 0) ? D_Blocks_Prefix_Sum[block_id - 1] : 0);
    for (int j = 0; j < Elements_Per_Block; j++) {
        Sub_String[thread_id + W - 1 + MAX_THREADS_PER_BLOCK * j] = ((r + MAX_THREADS_PER_BLOCK * j < n) ? Dev_Input[r + MAX_THREADS_PER_BLOCK * j] : 0);
        Prefix_Sum[thread_id + MAX_THREADS_PER_BLOCK * j] = 0;
    }

    if (thread_id < W - 1 && l < n)
        Sub_String[thread_id] = Dev_Input[l];

    __syncthreads();
    for (int j = 0; j < Elements_Per_Block && (r + MAX_THREADS_PER_BLOCK * j < n); j++) {
        int potenz_2_mod_P = 1;
        int res = 0;
        int l1 = thread_id + MAX_THREADS_PER_BLOCK * j;
        int r1 = l1 + W - 1;
        bool equal = true;
        for (int i = r1; i >= l1; i--) {
            equal = ((equal == true) ? Sub_String[i] == first_word_in_D[i - l1] : false);
            res = (res + potenz_2_mod_P * int(Sub_String[i])) % P;
            potenz_2_mod_P = (potenz_2_mod_P * 2) % P;
        }

        if ((res == 0 && (l > 0 || (l == 0 && l1 > 0))) || (equal && (l > 0 || (l == 0 && l1 > 0)))) {
            Prefix_Sum[l1] = 1;
        }
    }

    for (int stride = 1; stride < (MAX_THREADS_PER_BLOCK * Elements_Per_Block); stride <<= 1) {
        __syncthreads();
        for (int j = 0; j < Elements_Per_Block; j++) {
            int l1 = thread_id + MAX_THREADS_PER_BLOCK * j;

            if (l1 >= stride) {
                Saved_Sums[j] = Prefix_Sum[l1 - stride];

            }
        }
        __syncthreads();
        for (int j = 0; j < Elements_Per_Block; j++) {
            int l1 = thread_id + MAX_THREADS_PER_BLOCK * j;

            if (l1 >= stride) {
                Prefix_Sum[l1] = Prefix_Sum[l1] + Saved_Sums[j];
            }
        }
    }
    __syncthreads();
    for (int j = 0; j < Elements_Per_Block; j++) {
        int l1 = thread_id + MAX_THREADS_PER_BLOCK * j;
        if ((l1 > 0 && Prefix_Sum[l1] > Prefix_Sum[l1 - 1]) || (l1 == 0 && Prefix_Sum[0] > 0)) {
            int index = ((l1 > 0) ? Prefix_Sum[l1 - 1] : 0) + offset;
            int index_ans = r + MAX_THREADS_PER_BLOCK * j;

            D_Ends[index] = index_ans;

        }

    }


}

__global__ void Compute_D3(int* D_Ends, int n_enlarged, int size_D) {
    D_Ends[(size_D - 1)] = n_enlarged - 1;

}

__global__ void Compute_D4(int* D_Ends, int* D_Enlarged_Prefix_Sum, int size_D, int D_Word_Length_Cap) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int length_d = ((thread_id > 0) ? D_Ends[thread_id] - D_Ends[(thread_id - 1)] + W : D_Ends[thread_id] + 1);
        //if (length_d >= 8192 || length_d <= W)
            //   printf("%d ", length_d);
        //assert(length_d < 8192);
        assert(length_d > W);

        D_Enlarged_Prefix_Sum[thread_id] = (length_d + D_Word_Length_Cap - 1) / D_Word_Length_Cap;

    }
}

__global__ void Compute_D5(int* D_Enlarged_Prefix_Sum, int* D_Enlarged_Indexes, int size_D) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int index = ((thread_id > 0) ? D_Enlarged_Prefix_Sum[(thread_id - 1)] : 0);
        D_Enlarged_Indexes[index] = 1;

    }
}

__global__ void Init_D_Sorting_Left_To_Right(int* D_Enlarged_Prefix_Sum, int* D_Ends, int* D_Enlarged_Indexes, int* D_Sorting_Pos, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int size_D_Sorting, int D_Word_Length_Cap) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int d_index = D_Enlarged_Indexes[thread_id] - 1;

        int left_most = ((d_index > 0) ? D_Enlarged_Prefix_Sum[d_index - 1] : 0);
        int num_enlarged = thread_id - left_most;
        int d_end = D_Ends[d_index];
        int length_d = ((d_index > 0) ? d_end - D_Ends[d_index - 1] + W : D_Ends[d_index] + 1) - num_enlarged * D_Word_Length_Cap;
        int d_start = d_end - length_d + 1;

        D_Sorting_Pos[thread_id] = thread_id;
        D_Sorting_Text_Start[thread_id] = d_start;
        D_Sorting_Lenght[thread_id] = length_d;
        D_Sorting_Rank_Group[thread_id] = 0;


    }

}

__global__ void Init_D_Key_Left_And_Value_Left_To_Right1(int* D_Values_In, unsigned char* Dev_Input, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, unsigned long long* D_Key, int size_D_Sorting, int prefix_length, int cnt_word_length, int size_alphabet) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        unsigned char prefix_thread[32];
        int d_start = D_Sorting_Text_Start[thread_id] + prefix_length;
        int length_d = D_Sorting_Lenght[thread_id];
        int d_end = d_start + length_d;
        for (int j = cnt_word_length * 2 - 1; j >= 0; j--, d_start++)
            prefix_thread[j] = ((d_start < d_end) ? Dev_Input[d_start] : 0);

        D_Key[thread_id] = pack_2_cnt_word_length(prefix_thread, cnt_word_length, size_alphabet);
        D_Values_In[thread_id] = thread_id;

    }

}

__global__ void Init_D_Key_Left_And_Value_Left_To_Right2(int* D_Sorting_Rank_Group, int* D_Values_In, unsigned char* Dev_Input, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, unsigned long long* D_Key, int size_D_Sorting, int prefix_length, int cnt_word_length, int size_alphabet) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        unsigned char prefix_thread[32];
        int d_start = D_Sorting_Text_Start[thread_id] + prefix_length;
        int length_d = D_Sorting_Lenght[thread_id];
        int d_end = d_start + length_d;
        for (int j = cnt_word_length - 1; j >= 0; j--, d_start++)
            prefix_thread[j] = ((d_start < d_end) ? Dev_Input[d_start] : 0);

        D_Key[thread_id] = pack_cnt_word_length(prefix_thread, cnt_word_length, size_alphabet) | (((unsigned long long)(D_Sorting_Rank_Group[thread_id])) << 32);

        D_Values_In[thread_id] = thread_id;

    }

}

__global__ void Reduce_D_0(unsigned long long* D_Key, int* Prefix_Sum1, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        unsigned long long rank = D_Key[thread_id];

        bool cond1 = (thread_id == 0) || (thread_id > 0 && (rank != D_Key[thread_id - 1]));

        Prefix_Sum1[thread_id] = cond1;

    }
}

__global__ void D_Sort_Rearange_Values(int* D_Values_Out, int* D_Sorting_Pos, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int* D_Sorting_Pos_New, int* D_Sorting_Text_Start_New, int* D_Sorting_Lenght_New, int* D_Sorting_Rank_Group_New, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = D_Values_Out[thread_id];
        D_Sorting_Pos_New[thread_id] = D_Sorting_Pos[index];
        D_Sorting_Text_Start_New[thread_id] = D_Sorting_Text_Start[index];
        D_Sorting_Lenght_New[thread_id] = D_Sorting_Lenght[index];
        D_Sorting_Rank_Group_New[thread_id] = D_Sorting_Rank_Group[index];

    }

}

__global__ void Reduce_D_1(int* D_Sorting_Rank_Group, int* Prefix_Sum1, int* Prefix_Sum2, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        int rank_group = D_Sorting_Rank_Group[thread_id];
        bool cond1 = (thread_id == 0) || (thread_id > 0 && (Prefix_Sum1[thread_id] || rank_group != D_Sorting_Rank_Group[thread_id - 1]));
        bool cond2 = (thread_id == 0) || (thread_id > 0 && (rank_group != D_Sorting_Rank_Group[thread_id - 1]));


        Prefix_Sum1[thread_id] = cond1;
        Prefix_Sum2[thread_id] = cond2;
    }
}

__global__ void Reduce_D_2(int* Prefix_Sum1, int* Prefix_Sum2, int* Prefix_Sum3, int* Prefix_Sum4, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id];
        bool cond1 = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Prefix_Sum1[thread_id - 1]);

        if (cond1) {
            index--;
            Prefix_Sum3[index] = thread_id;
        }

        index = Prefix_Sum2[thread_id];
        cond1 = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Prefix_Sum2[thread_id - 1]);

        if (cond1) {
            index--;
            Prefix_Sum4[index] = thread_id;
        }
    }
}

__global__ void Reduce_D_3(int* D_Sorting_Rank_Group, int* Prefix_Sum1, int* Prefix_Sum2, int* Prefix_Sum3, int* Prefix_Sum4, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id] - 1;
        int left_most = Prefix_Sum3[index];

        int index_old = Prefix_Sum2[thread_id] - 1;
        int left_most_old = Prefix_Sum4[index_old];

        if (thread_id == left_most)
            Prefix_Sum2[thread_id] = 0;

        D_Sorting_Rank_Group[thread_id] += left_most - left_most_old;
        Prefix_Sum1[thread_id] = left_most;



    }
}

__global__ void Reduce_D_4(int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int* Prefix_Sum1, int* Prefix_Sum2, int size_D_Sorting, int prefix_length) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        int rank_group = D_Sorting_Rank_Group[thread_id];
        bool cond1 = (thread_id == 0) || (thread_id > 0 && (rank_group != D_Sorting_Rank_Group[thread_id - 1]));
        bool cond2 = (thread_id == size_D_Sorting - 1) || (thread_id < size_D_Sorting - 1 && (rank_group != D_Sorting_Rank_Group[thread_id + 1]));
        bool got_more_Characters_to_sort = D_Sorting_Lenght[thread_id] > prefix_length;
        bool is_not_one_element_rank_group = !(cond1 && cond2);

        if (is_not_one_element_rank_group && got_more_Characters_to_sort) {
            int left_most = Prefix_Sum1[thread_id];
            Prefix_Sum2[left_most] = 1;
        }

    }
}

__global__ void Reduce_D_5(int* Prefix_Sum1, int* Prefix_Sum2, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int left_most = Prefix_Sum1[thread_id];
        bool cond = Prefix_Sum2[left_most];
        Prefix_Sum1[thread_id] = cond;

    }
}
__global__ void Reduce_D_6(int* D_Ranks_Final, int* Prefix_Sum1, int* D_Sorting_Pos, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int* D_Sorting_Pos_New, int* D_Sorting_Text_Start_New, int* D_Sorting_Lenght_New, int* D_Sorting_Rank_Group_New, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id];

        bool cond = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Prefix_Sum1[thread_id - 1]);

        if (cond) {
            index--;
            D_Sorting_Pos_New[index] = D_Sorting_Pos[thread_id];
            D_Sorting_Text_Start_New[index] = D_Sorting_Text_Start[thread_id];
            D_Sorting_Lenght_New[index] = D_Sorting_Lenght[thread_id];
            D_Sorting_Rank_Group_New[index] = D_Sorting_Rank_Group[thread_id];
        }
        else
        {
            D_Ranks_Final[D_Sorting_Pos[thread_id]] = D_Sorting_Rank_Group[thread_id];
        }

    }
}


__global__ void Reduce_D_7(int* D_Sorting_Rank_Group, int* Prefix_Sum1, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        int rank_group = D_Sorting_Rank_Group[thread_id];
        bool cond1 = (thread_id == 0) || (thread_id > 0 && (rank_group != D_Sorting_Rank_Group[thread_id - 1]));
        Prefix_Sum1[thread_id] = cond1;


    }
}

__global__ void Reduce_D_8(int* D_Offsets, int* Prefix_Sum1, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id];
        bool cond = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Prefix_Sum1[thread_id - 1]);

        if (cond)
            D_Offsets[index - 1] = thread_id;

        if (thread_id == size_D_Sorting - 1)
            D_Offsets[index] = size_D_Sorting;

    }
}


__global__ void Update_D_Ranks_Final(int* D_Ranks_Final, int* D_Sorting_Rank_Group, int* D_Sorting_Pos, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = D_Sorting_Pos[thread_id];
        int rank = D_Sorting_Rank_Group[thread_id];

        D_Ranks_Final[index] = rank;

    }
}

__global__ void Init_D_Key_And_Values_Prefix_Doubling(int* D_Sorting_Rank_Group, int* D_Values_In, unsigned long long* D_Key, int* D_Ranks_Final, int* D_Sorting_Pos, int* D_Sorting_Lenght, int size_D_Sorting, int prefix_length, int stride) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = D_Sorting_Pos[thread_id];
        int length = D_Sorting_Lenght[thread_id];
        D_Key[thread_id] = ((length > prefix_length) ? D_Ranks_Final[index + stride] + 1 : 0) | (((unsigned long long)(D_Sorting_Rank_Group[thread_id])) << 32);
        D_Values_In[thread_id] = thread_id;
    }
}



__global__ void D_Sort_Rearange_Prefix_Doubling_Values(int* D_Values_Out, int* D_Sorting_Pos, int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int* D_Sorting_Pos_New, int* D_Sorting_Lenght_New, int* D_Sorting_Rank_Group_New, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = D_Values_Out[thread_id];
        D_Sorting_Pos_New[thread_id] = D_Sorting_Pos[index];
        D_Sorting_Lenght_New[thread_id] = D_Sorting_Lenght[index];
        D_Sorting_Rank_Group_New[thread_id] = D_Sorting_Rank_Group[index];

    }

}

__global__ void Reduce_D_Prefix_Doubling_6(int* D_Ranks_Final, int* Prefix_Sum1, int* D_Sorting_Pos, int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int* D_Sorting_Pos_New, int* D_Sorting_Lenght_New, int* D_Sorting_Rank_Group_New, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id];

        bool cond = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Prefix_Sum1[thread_id - 1]);
        int pos = D_Sorting_Pos[thread_id];
        if (cond) {
            index--;
            D_Sorting_Pos_New[index] = pos;
            D_Sorting_Lenght_New[index] = D_Sorting_Lenght[thread_id];
            D_Sorting_Rank_Group_New[index] = D_Sorting_Rank_Group[thread_id];
        }

        D_Ranks_Final[pos] = D_Sorting_Rank_Group[thread_id];


    }
}

__global__ void Get_D_Ranks_Left_To_Right(int* D_Ranks_Final, int* D_Ranks_Final_New, int* D_Sorting_Pos, int* D_Enlarged_Prefix_Sum, int size_D) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int index = ((thread_id > 0) ? D_Enlarged_Prefix_Sum[thread_id - 1] : 0);
        D_Ranks_Final_New[thread_id] = D_Ranks_Final[index];

    }
}

void Sort_D_Left_To_Rigth() {
    int size_D_Sorting = size_D_Enlarged;
    int num_blocks_size_D_Sorting = num_blocks_size_D_Enlarged;
    int prefix_length = 0;

    int* D_Sorting_Mem1;
    int* D_Sorting_Mem2;
    int* D_Sorting_Mem3;
    int* D_Sorting_Pos;
    int* D_Sorting_Pos_New;
    int* D_Sorting_Text_Start;
    int* D_Sorting_Text_Start_New;
    int* D_Sorting_Lenght;
    int* D_Sorting_Lenght_New;
    int* D_Sorting_Rank_Group;
    int* D_Sorting_Rank_Group_New;
    int* D_Values_In;
    int* D_Values_Out;
    unsigned long long* D_Key;
    unsigned long long* D_Key_New;

    int* D_Ranks_Final;
    cudaMalloc((void**)&D_Mem1, (11 * size_D_Enlarged) * sizeof(int));
    D_Sorting_Mem1 = D_Mem1;
    D_Sorting_Mem2 = D_Mem1 + 4 * size_D_Enlarged;
    D_Sorting_Mem3 = D_Mem1 + 8 * size_D_Enlarged;
    D_Ranks_Final = D_Mem1 + 10 * size_D_Enlarged;

    D_Key = (unsigned long long*)(D_Sorting_Mem1);
    D_Key_New = (unsigned long long*)(D_Sorting_Mem1 + 2 * size_D_Enlarged);

    D_Sorting_Pos = D_Sorting_Mem2;
    D_Sorting_Text_Start = D_Sorting_Mem2 + size_D_Enlarged;
    D_Sorting_Lenght = D_Sorting_Mem2 + 2 * size_D_Enlarged;
    D_Sorting_Rank_Group = D_Sorting_Mem2 + 3 * size_D_Enlarged;

    D_Sorting_Pos_New = D_Sorting_Mem1;
    D_Sorting_Text_Start_New = D_Sorting_Mem1 + size_D_Enlarged;
    D_Sorting_Lenght_New = D_Sorting_Mem1 + 2 * size_D_Enlarged;
    D_Sorting_Rank_Group_New = D_Sorting_Mem1 + 3 * size_D_Enlarged;

    D_Values_In = D_Sorting_Mem3;
    D_Values_Out = D_Sorting_Mem3 + size_D_Enlarged;

    Init_D_Sorting_Left_To_Right << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Enlarged_Prefix_Sum, D_Ends, D_Enlarged_Indexes, D_Sorting_Pos, D_Sorting_Text_Start, D_Sorting_Lenght, D_Sorting_Rank_Group, size_D_Sorting, D_Word_Length_Cap);

    //D_Start_Sort_Check = new int[size_D];
    //cudaMemcpy(D_Start_Sort_Check, D_Ends, (size_D) * sizeof(int), cudaMemcpyDeviceToHost);


    //D_Start_Sort_Check = new int[size_D_Enlarged];
    //D_Lenght_Sort_Check = new int[size_D_Enlarged];
    //cudaMemcpy(D_Start_Sort_Check, D_Sorting_Text_Start, (size_D_Enlarged) * sizeof(int), cudaMemcpyDeviceToHost);
    //cudaMemcpy(D_Lenght_Sort_Check, D_Sorting_Lenght, (size_D_Enlarged) * sizeof(int), cudaMemcpyDeviceToHost);
    int round = 0;
    int stride = 1;
    while (size_D_Sorting > 0) {
        if (round == 0) {
            Init_D_Key_Left_And_Value_Left_To_Right1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Dev_Input, D_Sorting_Text_Start, D_Sorting_Lenght, D_Key, size_D_Sorting, prefix_length, cnt_word_length, size_alphabet);
            prefix_length += cnt_word_length * 2;
            round++;
        }
        else if (round < D_Sort_Rounds) {
            Init_D_Key_Left_And_Value_Left_To_Right2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, D_Values_In, Dev_Input, D_Sorting_Text_Start, D_Sorting_Lenght, D_Key, size_D_Sorting, prefix_length, cnt_word_length, size_alphabet);
            prefix_length += cnt_word_length;
            round++;
        }
        else if (round == D_Sort_Rounds) {
            Update_D_Ranks_Final << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, D_Sorting_Rank_Group, D_Sorting_Pos, size_D_Sorting);
            Init_D_Key_And_Values_Prefix_Doubling << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, D_Values_In, D_Key, D_Ranks_Final, D_Sorting_Pos, D_Sorting_Lenght, size_D_Sorting, prefix_length, stride);
            prefix_length <<= 1;
            stride <<= 1;
            round++;
        }
        else {
            Init_D_Key_And_Values_Prefix_Doubling << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, D_Values_In, D_Key, D_Ranks_Final, D_Sorting_Pos, D_Sorting_Lenght, size_D_Sorting, prefix_length, stride);
            prefix_length <<= 1;
            stride <<= 1;
        }



        size_t   temp_storage_bytes = 0;

        cub::DeviceRadixSort::SortPairs(
            nullptr, temp_storage_bytes,
            D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);

        if (temp_storage_bytes > SegmentedSort_bytes) {

            if (SegmentedSort_bytes > 0)
                cudaFree(SegmentedSort_Temp_Storage);

            SegmentedSort_bytes = temp_storage_bytes;

            cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
        }

        cub::DeviceRadixSort::SortPairs(
            SegmentedSort_Temp_Storage, temp_storage_bytes,
            D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);


        int* Prefix_Sum1 = D_Values_In;
        int* Prefix_Sum2 = D_Values_Out;

        Reduce_D_0 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Key_New, Prefix_Sum1, size_D_Sorting);

        if (round < D_Sort_Rounds) {
            D_Sort_Rearange_Values << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_Out, D_Sorting_Pos, D_Sorting_Text_Start, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Text_Start_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }
        else {
            D_Sort_Rearange_Prefix_Doubling_Values << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_Out, D_Sorting_Pos, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }

        swap(D_Sorting_Mem1, D_Sorting_Mem2);

        D_Key = (unsigned long long*)(D_Sorting_Mem1);
        D_Key_New = (unsigned long long*)(D_Sorting_Mem1 + 2 * size_D_Enlarged);

        D_Sorting_Pos = D_Sorting_Mem2;
        D_Sorting_Text_Start = D_Sorting_Mem2 + size_D_Enlarged;
        D_Sorting_Lenght = D_Sorting_Mem2 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group = D_Sorting_Mem2 + 3 * size_D_Enlarged;

        D_Sorting_Pos_New = D_Sorting_Mem1;
        D_Sorting_Text_Start_New = D_Sorting_Mem1 + size_D_Enlarged;
        D_Sorting_Lenght_New = D_Sorting_Mem1 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group_New = D_Sorting_Mem1 + 3 * size_D_Enlarged;

        int* Prefix_Sum3 = D_Sorting_Mem1;
        int* Prefix_Sum4 = D_Sorting_Mem1 + size_D_Enlarged;

        Reduce_D_1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum2),
            thrust::device_pointer_cast(Prefix_Sum2 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum2)
        );

        Reduce_D_2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);

        Reduce_D_3 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);

        Reduce_D_4 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Lenght, D_Sorting_Rank_Group, Prefix_Sum1, Prefix_Sum2, size_D_Sorting, prefix_length);

        Reduce_D_5 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        int size_D_Sorting_New;
        cudaMemcpy(&size_D_Sorting_New, Prefix_Sum1 + size_D_Sorting - 1, sizeof(int), cudaMemcpyDeviceToHost);
        int num_blocks_size_D_Sorting_New = (size_D_Sorting_New + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

        if (round < D_Sort_Rounds) {
            Reduce_D_6 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, Prefix_Sum1, D_Sorting_Pos, D_Sorting_Text_Start, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Text_Start_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }
        else {
            Reduce_D_Prefix_Doubling_6 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, Prefix_Sum1, D_Sorting_Pos, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }



        size_D_Sorting = size_D_Sorting_New;
        num_blocks_size_D_Sorting = num_blocks_size_D_Sorting_New;

        swap(D_Sorting_Mem1, D_Sorting_Mem2);

        D_Key = (unsigned long long*)(D_Sorting_Mem1);
        D_Key_New = (unsigned long long*)(D_Sorting_Mem1 + 2 * size_D_Enlarged);

        D_Sorting_Pos = D_Sorting_Mem2;
        D_Sorting_Text_Start = D_Sorting_Mem2 + size_D_Enlarged;
        D_Sorting_Lenght = D_Sorting_Mem2 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group = D_Sorting_Mem2 + 3 * size_D_Enlarged;

        D_Sorting_Pos_New = D_Sorting_Mem1;
        D_Sorting_Text_Start_New = D_Sorting_Mem1 + size_D_Enlarged;
        D_Sorting_Lenght_New = D_Sorting_Mem1 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group_New = D_Sorting_Mem1 + 3 * size_D_Enlarged;

    }

    int* D_Ranks_Final_New = D_Mem1 + 6 * size_D_Enlarged;
    Get_D_Ranks_Left_To_Right << < num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, D_Ranks_Final_New, D_Sorting_Pos, D_Enlarged_Prefix_Sum, size_D);

    //D_Ranks_Sort_Check = new int[size_D_Enlarged];
    //cudaMemcpy(D_Ranks_Sort_Check, D_Ranks_Final, (size_D_Enlarged) * sizeof(int), cudaMemcpyDeviceToHost);


}


__global__ void Init_Parse_Sorting(int2* D_Values_In, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        D_Values_In[thread_id].x = thread_id;
        D_Values_In[thread_id].y = 0;


    }

}


__global__ void Init_Key_Parse_Sorting(unsigned long long* D_Key, int2* D_Values_In, int* D_Ranks_Final, int size_D, int size_D_Sorting, int stride) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = D_Values_In[thread_id].x + stride;

        D_Key[thread_id] = ((index < size_D) ? D_Ranks_Final[index] + 1 : 0) | (((unsigned long long)D_Values_In[thread_id].y) << 32);
    }
}


__global__ void Reduce_Parse_1(int2* D_Values_In, int* Prefix_Sum1, int* Prefix_Sum2, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        int rank_group = D_Values_In[thread_id].y;

        bool cond1 = (thread_id == 0) || (thread_id > 0 && (Prefix_Sum1[thread_id] || rank_group != D_Values_In[thread_id - 1].y));
        bool cond2 = (thread_id == 0) || (thread_id > 0 && (rank_group != D_Values_In[thread_id - 1].y));


        Prefix_Sum1[thread_id] = cond1;
        Prefix_Sum2[thread_id] = cond2;

    }
}

__global__ void Reduce_Parse_3(int2* D_Values_In, int* Prefix_Sum1, int* Prefix_Sum2, int* Prefix_Sum3, int* Prefix_Sum4, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id] - 1;
        int left_most = Prefix_Sum3[index];

        int index_old = Prefix_Sum2[thread_id] - 1;
        int left_most_old = Prefix_Sum4[index_old];

        D_Values_In[thread_id].y += left_most - left_most_old;

    }
}


__global__ void Reduce_Parse_4(int2* D_Values_In, int* Prefix_Sum1, int* Prefix_Sum2, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {


        int rank_group = D_Values_In[thread_id].y;
        bool cond1 = (thread_id == 0) || (thread_id > 0 && (rank_group != D_Values_In[thread_id - 1].y));
        bool cond2 = (thread_id == size_D_Sorting - 1) || (thread_id < size_D_Sorting - 1 && (rank_group != D_Values_In[thread_id + 1].y));

        bool is_not_one_element_rank_group = !(cond1 && cond2);

        Prefix_Sum1[thread_id] = is_not_one_element_rank_group;



    }
}

__global__ void Reduce_Parse_6(int* D_Ranks_Final, int2* D_Values_In, int2* D_Values_Out, int* Prefix_Sum1, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id];

        bool cond = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Prefix_Sum1[thread_id - 1]);
        int pos = D_Values_In[thread_id].x;
        int rank = D_Values_In[thread_id].y;
        if (cond) {
            index--;
            D_Values_Out[index].x = pos;
            D_Values_Out[index].y = rank;
        }

        D_Ranks_Final[pos] = rank;

    }
}

__global__ void Reduce_Parse_7(int2* D_Values_In, int* Prefix_Sum1, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {


        int rank_group = D_Values_In[thread_id].y;
        bool cond1 = (thread_id == 0) || (thread_id > 0 && (rank_group != D_Values_In[thread_id - 1].y));
        Prefix_Sum1[thread_id] = cond1;


    }
}

__global__ void Init_Right_To_Left_Sort1(int2* D_Values_In, int* Prefix_Sum1, int* D_Enlarged_Prefix_Sum, int* Prefix_Sum2, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {

        int index = D_Values_In[thread_id].x;
        if (Prefix_Sum1[thread_id]) {
            D_Enlarged_Prefix_Sum[index] = ((index > 0) ? Prefix_Sum2[index] - Prefix_Sum2[index - 1] : Prefix_Sum2[index]);
        }
        else {
            D_Enlarged_Prefix_Sum[index] = 0;
        }


    }
}



__global__ void Init_Right_To_Left_Sort2(int2* D_Values_In, int* Prefix_Sum1, int* Prefix_Sum3, int* D_Enlarged_Prefix_Sum, int* D_Duplicate_Mapping, int size_D_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int index = Prefix_Sum1[thread_id] - 1;
        int left_most = Prefix_Sum3[index];

        int id = D_Values_In[left_most].x;
        D_Duplicate_Mapping[D_Values_In[thread_id].x] = (id > 0) ? D_Enlarged_Prefix_Sum[id - 1] : 0;

    }
}

void Sort_Parse() {

    int size_D_Sorting = size_D;
    int num_blocks_size_D_Sorting = num_blocks_size_D;
    int stride = 0;

    int2* D_Values_In;
    int2* D_Values_Out;
    unsigned long long* D_Key;
    unsigned long long* D_Key_New;

    int* D_Ranks_Final;

    D_Values_In = (int2*)D_Mem1;
    D_Values_Out = (int2*)(D_Mem1 + size_D_Enlarged * 2);
    D_Key = (unsigned long long*)(D_Mem1 + size_D_Enlarged * 4);
    D_Key_New = (unsigned long long*)(D_Mem1 + size_D_Enlarged * 6);
    D_Ranks_Final = D_Mem1 + 10 * size_D_Enlarged;

    Init_Parse_Sorting << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, size_D_Sorting);

    Init_Key_Parse_Sorting << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Key, D_Values_In, D_Mem1 + 6 * size_D_Enlarged, size_D, size_D_Sorting, stride);

    stride = 1;

    size_t   temp_storage_bytes = 0;

    cub::DeviceRadixSort::SortPairs(
        nullptr, temp_storage_bytes,
        D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);

    if (temp_storage_bytes > SegmentedSort_bytes) {

        if (SegmentedSort_bytes > 0)
            cudaFree(SegmentedSort_Temp_Storage);

        SegmentedSort_bytes = temp_storage_bytes;

        cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
    }

    cub::DeviceRadixSort::SortPairs(
        SegmentedSort_Temp_Storage, temp_storage_bytes,
        D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);

    swap(D_Values_In, D_Values_Out);

    int* Prefix_Sum1 = (int*)D_Key;
    int* Prefix_Sum2 = (int*)D_Key_New;

    Reduce_D_0 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Key_New, Prefix_Sum1, size_D_Sorting);

    cudaMemcpy(Prefix_Sum2, D_Enlarged_Prefix_Sum, size_D_Sorting * sizeof(int), cudaMemcpyDeviceToDevice);

    Init_Right_To_Left_Sort1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Prefix_Sum1, D_Enlarged_Prefix_Sum, Prefix_Sum2, size_D_Sorting);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(D_Enlarged_Prefix_Sum),
        thrust::device_pointer_cast(D_Enlarged_Prefix_Sum + size_D_Sorting),
        thrust::device_pointer_cast(D_Enlarged_Prefix_Sum)
    );

    cudaMemcpy(&size_D_Enlarged_without_duplicates, D_Enlarged_Prefix_Sum + size_D_Sorting - 1, sizeof(int), cudaMemcpyDeviceToHost);
    num_blocks_size_D_Enlarged_without_duplicates = (size_D_Enlarged_without_duplicates + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

    Reduce_Parse_1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(Prefix_Sum1),
        thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
        thrust::device_pointer_cast(Prefix_Sum1)
    );

    thrust::inclusive_scan(
        thrust::device_pointer_cast(Prefix_Sum2),
        thrust::device_pointer_cast(Prefix_Sum2 + size_D_Sorting),
        thrust::device_pointer_cast(Prefix_Sum2)
    );
    int* Prefix_Sum3 = (int*)D_Values_Out;
    int* Prefix_Sum4 = Prefix_Sum3 + size_D;

    Reduce_D_2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);

    D_Duplicate_Mapping = D_Mem1 + 8 * size_D_Enlarged;

    Init_Right_To_Left_Sort2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Prefix_Sum1, Prefix_Sum3, D_Enlarged_Prefix_Sum, D_Duplicate_Mapping, size_D_Sorting);

    while (size_D_Sorting > 0) {


        Reduce_Parse_3 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);

        Reduce_Parse_4 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        int size_D_Sorting_New;
        cudaMemcpy(&size_D_Sorting_New, Prefix_Sum1 + size_D_Sorting - 1, sizeof(int), cudaMemcpyDeviceToHost);
        int num_blocks_size_D_Sorting_New = (size_D_Sorting_New + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

        Reduce_Parse_6 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, D_Values_In, D_Values_Out, Prefix_Sum1, size_D_Sorting);

        swap(D_Values_In, D_Values_Out);

        size_D_Sorting = size_D_Sorting_New;
        num_blocks_size_D_Sorting = num_blocks_size_D_Sorting_New;

        if (size_D_Sorting == 0)
            break;

        Init_Key_Parse_Sorting << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Key, D_Values_In, D_Ranks_Final, size_D, size_D_Sorting, stride);

        stride <<= 1;

        cub::DeviceRadixSort::SortPairs(
            nullptr, temp_storage_bytes,
            D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);

        if (temp_storage_bytes > SegmentedSort_bytes) {

            if (SegmentedSort_bytes > 0)
                cudaFree(SegmentedSort_Temp_Storage);

            SegmentedSort_bytes = temp_storage_bytes;

            cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
        }

        cub::DeviceRadixSort::SortPairs(
            SegmentedSort_Temp_Storage, temp_storage_bytes,
            D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);

        swap(D_Values_In, D_Values_Out);

        Reduce_D_0 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Key_New, Prefix_Sum1, size_D_Sorting);

        Reduce_Parse_1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum2),
            thrust::device_pointer_cast(Prefix_Sum2 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum2)
        );
        Prefix_Sum3 = (int*)D_Values_Out;
        Prefix_Sum4 = Prefix_Sum3 + size_D_Enlarged;

        Reduce_D_2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);
    }
    //D_Ranks_Sort_Check = new int[size_D_Enlarged];
    //cudaMemcpy(D_Ranks_Sort_Check, D_Ranks_Final, (size_D_Enlarged) * sizeof(int), cudaMemcpyDeviceToHost);
}



__global__ void Init_D_Sorting_Right_To_Left_1(int* D_Enlarged_Prefix_Sum, int* D_Enlarged_Indexes, int size_D) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int index = ((thread_id > 0) ? D_Enlarged_Prefix_Sum[thread_id - 1] : 0);
        bool cond1 = (thread_id == 0 && D_Enlarged_Prefix_Sum[thread_id] > 0) || (thread_id > 0 && D_Enlarged_Prefix_Sum[thread_id] > index);
        if (cond1) {
            D_Enlarged_Indexes[index] = thread_id;

            // if (index == 25659)
               //   printf("sdvsdg");
        }

    }
}


__global__ void Init_D_Sorting_Right_To_Left_2(int* D_Ranks_Final, int* D_Enlarged_Prefix_Sum, int* D_Ends, int* D_Enlarged_Indexes, int* D_Sorting_Pos, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, int* D_Sorting_Rank_Group, int size_D_Sorting, int D_Word_Length_Cap) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        int d_index = D_Enlarged_Indexes[thread_id];
        //7 1365518 1380085 85 160
        int left_most = ((d_index > 0) ? D_Enlarged_Prefix_Sum[d_index - 1] : 0);
        int num_enlarged = thread_id - left_most;
        int d_end = D_Ends[d_index];

        int length_d = ((d_index > 0) ? d_end - D_Ends[d_index - 1] + W : D_Ends[d_index] + 1) - num_enlarged * D_Word_Length_Cap;
        int d_start = d_end - num_enlarged * D_Word_Length_Cap;

        D_Sorting_Pos[thread_id] = thread_id;
        D_Sorting_Text_Start[thread_id] = d_start;
        D_Sorting_Lenght[thread_id] = length_d;
        D_Sorting_Rank_Group[thread_id] = 0;


    }
}





__global__ void Init_D_Key_Left_And_Value_Right_To_Left1(int* D_Values_In, unsigned char* Dev_Input, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, unsigned long long* D_Key, int size_D_Sorting, int prefix_length, int cnt_word_length, int size_alphabet) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        unsigned char prefix_thread[32];
        int r = D_Sorting_Text_Start[thread_id];
        int d_start = r - prefix_length;
        int length_d = D_Sorting_Lenght[thread_id];
        int d_end = r - length_d;

        for (int j = cnt_word_length * 2 - 1; j >= 0; j--, d_start--)
            prefix_thread[j] = ((d_start > d_end) ? Dev_Input[d_start] : 0);

        D_Key[thread_id] = pack_2_cnt_word_length(prefix_thread, cnt_word_length, size_alphabet);
        D_Values_In[thread_id] = thread_id;

    }

}

__global__ void Init_D_Key_Left_And_Value_Right_To_Left2(int* D_Sorting_Rank_Group, int* D_Values_In, unsigned char* Dev_Input, int* D_Sorting_Text_Start, int* D_Sorting_Lenght, unsigned long long* D_Key, int size_D_Sorting, int prefix_length, int cnt_word_length, int size_alphabet) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D_Sorting) {
        unsigned char prefix_thread[32];
        int r = D_Sorting_Text_Start[thread_id];
        int d_start = r - prefix_length;
        int length_d = D_Sorting_Lenght[thread_id];
        int d_end = r - length_d;

        for (int j = cnt_word_length - 1; j >= 0; j--, d_start--)
            prefix_thread[j] = ((d_start > d_end) ? Dev_Input[d_start] : 0);

        D_Key[thread_id] = pack_cnt_word_length(prefix_thread, cnt_word_length, size_alphabet) | (((unsigned long long)(D_Sorting_Rank_Group[thread_id])) << 32);
        D_Values_In[thread_id] = thread_id;

    }

}

void Sort_D_Rigth_To_Left() {
    int size_D_Sorting = size_D_Enlarged_without_duplicates;
    int num_blocks_size_D_Sorting = num_blocks_size_D_Enlarged_without_duplicates;
    int prefix_length = 0;

    int* D_Sorting_Mem1;
    int* D_Sorting_Mem2;
    int* D_Sorting_Mem3;
    int* D_Sorting_Pos;
    int* D_Sorting_Pos_New;
    int* D_Sorting_Text_Start;
    int* D_Sorting_Text_Start_New;
    int* D_Sorting_Lenght;
    int* D_Sorting_Lenght_New;
    int* D_Sorting_Rank_Group;
    int* D_Sorting_Rank_Group_New;
    int* D_Values_In;
    int* D_Values_Out;
    unsigned long long* D_Key;
    unsigned long long* D_Key_New;

    int* D_Ranks_Final;

    D_Sorting_Mem1 = D_Mem1;
    D_Sorting_Mem2 = D_Mem1 + 4 * size_D_Enlarged;
    D_Sorting_Mem3 = D_Mem1 + 8 * size_D_Enlarged;
    D_Ranks_Final = D_Mem1 + 10 * size_D_Enlarged;

    D_Key = (unsigned long long*)(D_Sorting_Mem1);
    D_Key_New = (unsigned long long*)(D_Sorting_Mem1 + 2 * size_D_Enlarged);

    D_Sorting_Pos = D_Sorting_Mem2;
    D_Sorting_Text_Start = D_Sorting_Mem2 + size_D_Enlarged;
    D_Sorting_Lenght = D_Sorting_Mem2 + 2 * size_D_Enlarged;
    D_Sorting_Rank_Group = D_Sorting_Mem2 + 3 * size_D_Enlarged;

    D_Sorting_Pos_New = D_Sorting_Mem1;
    D_Sorting_Text_Start_New = D_Sorting_Mem1 + size_D_Enlarged;
    D_Sorting_Lenght_New = D_Sorting_Mem1 + 2 * size_D_Enlarged;
    D_Sorting_Rank_Group_New = D_Sorting_Mem1 + 3 * size_D_Enlarged;

    D_Values_In = D_Sorting_Mem3;
    D_Values_Out = D_Sorting_Mem3 + size_D_Enlarged;

    Init_Vector << <num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Enlarged_Indexes, size_D_Sorting, -1);

    Init_D_Sorting_Right_To_Left_1 << < num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (D_Enlarged_Prefix_Sum, D_Enlarged_Indexes, size_D);

    Pointer_Jumping(D_Enlarged_Indexes, D_Mem1, size_D_Sorting);

    Init_D_Sorting_Right_To_Left_2 << <num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, D_Enlarged_Prefix_Sum, D_Ends, D_Enlarged_Indexes, D_Sorting_Pos, D_Sorting_Text_Start, D_Sorting_Lenght, D_Sorting_Rank_Group, size_D_Sorting, D_Word_Length_Cap);

    cudaMemcpy(D_Enlarged_Indexes, D_Duplicate_Mapping, size_D * sizeof(int), cudaMemcpyDeviceToDevice);

    cudaMemcpy(D_Enlarged_Prefix_Sum, D_Ranks_Final, size_D * sizeof(int), cudaMemcpyDeviceToDevice);


    //D_Start_Sort_Check = new int[size_D_Enlarged];
    //D_Lenght_Sort_Check = new int[size_D_Enlarged];
    //cudaMemcpy(D_Start_Sort_Check, D_Sorting_Text_Start, (size_D_Enlarged) * sizeof(int), cudaMemcpyDeviceToHost);
   // cudaMemcpy(D_Lenght_Sort_Check, D_Sorting_Lenght, (size_D_Enlarged) * sizeof(int), cudaMemcpyDeviceToHost);

    int round = 0;
    int stride = 1;
    while (size_D_Sorting > 0) {
        if (round == 0) {
            Init_D_Key_Left_And_Value_Right_To_Left1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_In, Dev_Input, D_Sorting_Text_Start, D_Sorting_Lenght, D_Key, size_D_Sorting, prefix_length, cnt_word_length, size_alphabet);
            prefix_length += cnt_word_length * 2;
            round++;
        }
        else if (round < D_Sort_Rounds) {
            Init_D_Key_Left_And_Value_Right_To_Left2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, D_Values_In, Dev_Input, D_Sorting_Text_Start, D_Sorting_Lenght, D_Key, size_D_Sorting, prefix_length, cnt_word_length, size_alphabet);
            prefix_length += cnt_word_length;
            round++;
        }
        else if (round == D_Sort_Rounds) {
            Update_D_Ranks_Final << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, D_Sorting_Rank_Group, D_Sorting_Pos, size_D_Sorting);
            Init_D_Key_And_Values_Prefix_Doubling << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, D_Values_In, D_Key, D_Ranks_Final, D_Sorting_Pos, D_Sorting_Lenght, size_D_Sorting, prefix_length, stride);
            prefix_length <<= 1;
            stride <<= 1;
            round++;
        }
        else {
            Init_D_Key_And_Values_Prefix_Doubling << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, D_Values_In, D_Key, D_Ranks_Final, D_Sorting_Pos, D_Sorting_Lenght, size_D_Sorting, prefix_length, stride);
            prefix_length <<= 1;
            stride <<= 1;
        }

        size_t   temp_storage_bytes = 0;

        cub::DeviceRadixSort::SortPairs(
            nullptr, temp_storage_bytes,
            D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);

        if (temp_storage_bytes > SegmentedSort_bytes) {

            if (SegmentedSort_bytes > 0)
                cudaFree(SegmentedSort_Temp_Storage);

            SegmentedSort_bytes = temp_storage_bytes;

            cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
        }

        cub::DeviceRadixSort::SortPairs(
            SegmentedSort_Temp_Storage, temp_storage_bytes,
            D_Key, D_Key_New, D_Values_In, D_Values_Out, size_D_Sorting);


        int* Prefix_Sum1 = D_Values_In;
        int* Prefix_Sum2 = D_Values_Out;

        Reduce_D_0 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Key_New, Prefix_Sum1, size_D_Sorting);

        if (round < D_Sort_Rounds) {
            D_Sort_Rearange_Values << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_Out, D_Sorting_Pos, D_Sorting_Text_Start, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Text_Start_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }
        else {
            D_Sort_Rearange_Prefix_Doubling_Values << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Values_Out, D_Sorting_Pos, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }

        swap(D_Sorting_Mem1, D_Sorting_Mem2);

        D_Key = (unsigned long long*)(D_Sorting_Mem1);
        D_Key_New = (unsigned long long*)(D_Sorting_Mem1 + 2 * size_D_Enlarged);

        D_Sorting_Pos = D_Sorting_Mem2;
        D_Sorting_Text_Start = D_Sorting_Mem2 + size_D_Enlarged;
        D_Sorting_Lenght = D_Sorting_Mem2 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group = D_Sorting_Mem2 + 3 * size_D_Enlarged;

        D_Sorting_Pos_New = D_Sorting_Mem1;
        D_Sorting_Text_Start_New = D_Sorting_Mem1 + size_D_Enlarged;
        D_Sorting_Lenght_New = D_Sorting_Mem1 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group_New = D_Sorting_Mem1 + 3 * size_D_Enlarged;

        int* Prefix_Sum3 = D_Sorting_Mem1;
        int* Prefix_Sum4 = D_Sorting_Mem1 + size_D_Enlarged;

        Reduce_D_1 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum2),
            thrust::device_pointer_cast(Prefix_Sum2 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum2)
        );

        Reduce_D_2 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);

        Reduce_D_3 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Rank_Group, Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_D_Sorting);

        Reduce_D_4 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Sorting_Lenght, D_Sorting_Rank_Group, Prefix_Sum1, Prefix_Sum2, size_D_Sorting, prefix_length);

        Reduce_D_5 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, size_D_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_D_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        int size_D_Sorting_New;
        cudaMemcpy(&size_D_Sorting_New, Prefix_Sum1 + size_D_Sorting - 1, sizeof(int), cudaMemcpyDeviceToHost);
        int num_blocks_size_D_Sorting_New = (size_D_Sorting_New + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

        if (round < D_Sort_Rounds) {
            Reduce_D_6 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, Prefix_Sum1, D_Sorting_Pos, D_Sorting_Text_Start, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Text_Start_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }
        else {
            Reduce_D_Prefix_Doubling_6 << < num_blocks_size_D_Sorting, MAX_THREADS_PER_BLOCK >> > (D_Ranks_Final, Prefix_Sum1, D_Sorting_Pos, D_Sorting_Lenght, D_Sorting_Rank_Group, D_Sorting_Pos_New, D_Sorting_Lenght_New, D_Sorting_Rank_Group_New, size_D_Sorting);
        }

        size_D_Sorting = size_D_Sorting_New;
        num_blocks_size_D_Sorting = num_blocks_size_D_Sorting_New;

        swap(D_Sorting_Mem1, D_Sorting_Mem2);

        D_Key = (unsigned long long*)(D_Sorting_Mem1);
        D_Key_New = (unsigned long long*)(D_Sorting_Mem1 + 2 * size_D_Enlarged);

        D_Sorting_Pos = D_Sorting_Mem2;
        D_Sorting_Text_Start = D_Sorting_Mem2 + size_D_Enlarged;
        D_Sorting_Lenght = D_Sorting_Mem2 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group = D_Sorting_Mem2 + 3 * size_D_Enlarged;

        D_Sorting_Pos_New = D_Sorting_Mem1;
        D_Sorting_Text_Start_New = D_Sorting_Mem1 + size_D_Enlarged;
        D_Sorting_Lenght_New = D_Sorting_Mem1 + 2 * size_D_Enlarged;
        D_Sorting_Rank_Group_New = D_Sorting_Mem1 + 3 * size_D_Enlarged;

    }
}

__global__ void Compute_D6(unsigned char* Dev_Input, unsigned long long* D_Key, int* D_Parse_Ranks, int* D_Ends, int* D_Duplicate_Mapping, int* D_Ranks_Final, int* D_New, int* D_Value_In, int size_D, int size_Dev_Input) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int d_end = D_Ends[thread_id];
        int length_d = ((thread_id > 0) ? d_end - D_Ends[(thread_id - 1)] + W : d_end + 1);
        int d_parse_rank = ((thread_id < size_D - 1) ? D_Parse_Ranks[thread_id + 1] + 1 : 0);

        D_New[thread_id] = d_end;
        D_New[thread_id + size_D] = length_d;
        D_New[thread_id + 2 * size_D] = d_parse_rank;

        int index = D_Duplicate_Mapping[thread_id];


        int text_index = ((d_end - length_d >= 0) ? d_end - length_d : size_Dev_Input - W - 1);
        unsigned char preceeding_character = Dev_Input[text_index];
        D_Key[thread_id] = (((unsigned long long)D_Ranks_Final[index]) << 8) | preceeding_character;

        D_Value_In[thread_id] = thread_id;
    }
}

__global__ void Compute_D7(int* D_Value_Out, int* D_New, int* D, int size_D) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int index = D_Value_Out[thread_id];
        D[thread_id] = D_New[index];
        D[thread_id + size_D] = D_New[index + size_D];
        D[thread_id + 2 * size_D] = D_New[index + 2 * size_D];
    }
}


void Compute_D() {
    cudaMalloc((void**)&Auxiliar1, num_blocks_n_enlarged * sizeof(int));
    int* D_Blocks_Prefix_Sum = Auxiliar1;

    Compute_D1 << <num_blocks_n, MAX_THREADS_PER_BLOCK >> > (Dev_Input, D_Blocks_Prefix_Sum, n);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(D_Blocks_Prefix_Sum),
        thrust::device_pointer_cast(D_Blocks_Prefix_Sum + num_blocks_n),
        thrust::device_pointer_cast(D_Blocks_Prefix_Sum)
    );

    cudaMemcpy(&size_D, D_Blocks_Prefix_Sum + (num_blocks_n - 1), sizeof(int), cudaMemcpyDeviceToHost);

    size_D++;

    cudaMalloc((void**)&D_Ends, (size_D) * sizeof(int));
    cudaMalloc((void**)&D_Enlarged_Prefix_Sum, (size_D) * sizeof(int));

    num_blocks_size_D = (size_D + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

    Compute_D2 << <num_blocks_n, MAX_THREADS_PER_BLOCK >> > (Dev_Input, D_Blocks_Prefix_Sum, D_Ends, n);

    Compute_D3 << <1, 1 >> > (D_Ends, n_enlarged, size_D);

    cudaFree(D_Blocks_Prefix_Sum);

    Compute_D4 << <num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (D_Ends, D_Enlarged_Prefix_Sum, size_D, D_Word_Length_Cap);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(D_Enlarged_Prefix_Sum),
        thrust::device_pointer_cast(D_Enlarged_Prefix_Sum + size_D),
        thrust::device_pointer_cast(D_Enlarged_Prefix_Sum)
    );

    cudaMemcpy(&size_D_Enlarged, D_Enlarged_Prefix_Sum + size_D - 1, sizeof(int), cudaMemcpyDeviceToHost);
    num_blocks_size_D_Enlarged = (size_D_Enlarged + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

    cudaMalloc((void**)&D_Enlarged_Indexes, (size_D_Enlarged) * sizeof(int));

    Init_Vector << <num_blocks_size_D_Enlarged, MAX_THREADS_PER_BLOCK >> > (D_Enlarged_Indexes, size_D_Enlarged, 0);

    Compute_D5 << <num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (D_Enlarged_Prefix_Sum, D_Enlarged_Indexes, size_D);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(D_Enlarged_Indexes),
        thrust::device_pointer_cast(D_Enlarged_Indexes + size_D_Enlarged),
        thrust::device_pointer_cast(D_Enlarged_Indexes)
    );

    Sort_D_Left_To_Rigth();

    Sort_Parse();

    Sort_D_Rigth_To_Left();

    int* D_Ranks_Final = D_Mem1 + size_D_Enlarged * 10;
    int* D_Parse_Ranks = D_Enlarged_Prefix_Sum;
    D_Duplicate_Mapping = D_Enlarged_Indexes;
    unsigned long long* D_Key = (unsigned long long*)D_Mem1;
    unsigned long long* D_Key_New = (unsigned long long*)(D_Mem1 + size_D * 2);
    int* D_Value_In = D_Mem1 + 4 * size_D;
    int* D_Value_Out = D_Mem1 + 5 * size_D;
    int* D_New = D_Mem1 + 6 * size_D;

    Compute_D6 << <num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (Dev_Input, D_Key, D_Parse_Ranks, D_Ends, D_Duplicate_Mapping, D_Ranks_Final, D_New, D_Value_In, size_D, n_enlarged);

    cudaFree(D_Ends);
    cudaFree(D_Enlarged_Indexes);
    cudaFree(D_Enlarged_Prefix_Sum);

    cudaMalloc((void**)&D, (3 * size_D) * sizeof(int));

    size_t temp_storage_bytes;

    cub::DeviceRadixSort::SortPairs(
        nullptr, temp_storage_bytes,
        D_Key, D_Key_New, D_Value_In, D_Value_Out, size_D, 0, 40);

    if (temp_storage_bytes > SegmentedSort_bytes) {

        if (SegmentedSort_bytes > 0)
            cudaFree(SegmentedSort_Temp_Storage);

        SegmentedSort_bytes = temp_storage_bytes;

        cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
    }

    cub::DeviceRadixSort::SortPairs(
        SegmentedSort_Temp_Storage, temp_storage_bytes,
        D_Key, D_Key_New, D_Value_In, D_Value_Out, size_D, 0, 40);


    Compute_D7 << <num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (D_Value_Out, D_New, D, size_D);

    cudaFree(D_Mem1);
    if (SegmentedSort_bytes > 0)
        cudaFree(SegmentedSort_Temp_Storage);

}

__global__ void Compute_S1(int* D, unsigned char* Dev_Input, int* Prefix_Sum, int* L_Values, int size_D) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {


        int val11 = D[thread_id];
        int val12 = D[thread_id + 1 * size_D];

        if (thread_id == 0) {
            Prefix_Sum[0] = val12;
            L_Values[0] = 0;
        }
        else {



            int val21 = D[thread_id - 1];
            int val22 = D[thread_id - 1 + 1 * size_D];


            int cnt_prefix_length = 0;

            for (int index_val1 = val11, index_val2 = val21; index_val1 >= val11 - val12 + 1 && index_val2 >= val21 - val22 + 1; index_val1--, index_val2--, cnt_prefix_length++) {
                unsigned char char_val1 = Dev_Input[index_val1];
                unsigned char char_val2 = Dev_Input[index_val2];
                if (char_val1 > char_val2) {

                    break;
                }
                else if (char_val1 < char_val2) {
                    //printf("\n %d %d %d", thread_id, val21, cnt_prefix_length);
                    break;
                }
            }
            Prefix_Sum[thread_id] = val12 - cnt_prefix_length;

            L_Values[thread_id] = cnt_prefix_length;


        }

    }



}

__global__ void Compute_L_Values_Min_Tree(int* L_Values_Min_Tree, int size, int offset) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size) {
        int index = thread_id + offset;
        int left_child = index << 1;
        L_Values_Min_Tree[index] = minimum(L_Values_Min_Tree[left_child], L_Values_Min_Tree[left_child + 1]);
    }
}


__device__ int find_leftmost_samller_right(int* L_Values_Min_Tree, int length_cur, int d_index, int size_D, int offset) {
    int cur_index = d_index + 1 + offset;
    if (d_index + 1 == size_D || L_Values_Min_Tree[cur_index] < length_cur)
        return 0;
    else {
        int found_node;
        bool found = false;

        while (cur_index > 1) {

            if ((cur_index & 1) == 0) {
                int right_sibling = cur_index + 1;
                if (L_Values_Min_Tree[right_sibling] < length_cur) {
                    found_node = right_sibling;
                    found = true;
                    break;
                }
            }
            cur_index >>= 1;
        }


        if (found) {
            while (found_node < offset) {
                int left_child = found_node << 1;
                if (L_Values_Min_Tree[left_child] < length_cur) {
                    found_node = left_child;
                }
                else {
                    found_node = left_child + 1;
                }
            }
            return found_node - offset - 1 - d_index;
        }
        else
            return size_D - d_index - 1;

    }
}

__device__ int find_rightmost_samller_left(int* Prefix_Sum, int* L_Values_Min_Tree, int length_cur, int d_index, int size_D, int offset, int index_S) {


    if (d_index == 0 || length_cur == 0)
        return index_S;

    else {
        int cur_index = d_index + offset - 1;
        int cur_L_Value = L_Values_Min_Tree[cur_index];
        if (cur_L_Value < length_cur) {
            return ((d_index >= 2) ? Prefix_Sum[d_index - 2] : 0) + (length_cur - cur_L_Value - 1);
        }
        else {


            int found_node;
            bool found = false;

            while (cur_index > 1) {

                if (cur_index & 1) {
                    int left_sibling = cur_index - 1;
                    if (L_Values_Min_Tree[left_sibling] < length_cur) {
                        found_node = left_sibling;
                        found = true;
                        break;
                    }
                }
                cur_index >>= 1;
            }


            assert(found);
            while (found_node < offset) {
                int left_child = found_node << 1;
                if (L_Values_Min_Tree[left_child + 1] < length_cur) {
                    found_node = left_child + 1;
                }
                else {
                    found_node = left_child;
                }
            }

            return ((found_node - offset >= 1) ? Prefix_Sum[found_node - offset - 1] : 0) + (length_cur - L_Values_Min_Tree[found_node] - 1);


        }
    }
}

__global__ void Compute_S2(int* S_Pointer_Jumping1, int* S_L, int* S_Length_Suffix, int* S_Interval_Length, int* D, int* Prefix_Sum, int* L_Values_Min_Tree, int size_D, int size_S, int offset) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_D) {
        int num_suffixes_l = ((thread_id > 0) ? Prefix_Sum[thread_id] - Prefix_Sum[(thread_id)-1] : Prefix_Sum[0]);
        int offset_l = ((thread_id > 0) ? Prefix_Sum[thread_id - 1] : 0);

        int val12 = D[thread_id + 1 * size_D];

        int l = val12 - num_suffixes_l;
        int r = val12;
        for (int i = l; i < r; i++) {
            int index = i - l + offset_l;
            int length_cur = i + 1;
            S_Length_Suffix[index] = length_cur;
            S_L[index] = thread_id;

            int interval_length = find_leftmost_samller_right(L_Values_Min_Tree, length_cur, thread_id, size_D, offset);
            S_Interval_Length[index] = interval_length;

            S_Pointer_Jumping1[index] = ((i == l) ? find_rightmost_samller_left(Prefix_Sum, L_Values_Min_Tree, i, thread_id, size_D, offset, index) : (index - (i > 0)));

        }

    }
}


__global__ void Reduce_S_5(int* S_Rank, int* S_L, int* S_Interval_Length, int* S_Length_Suffix, int* S_L_New, int* S_Interval_Length_New, int* S_Length_Suffix_New, int size_S) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_S) {
        int index = S_Rank[thread_id];

        S_L_New[index] = S_L[thread_id];
        S_Interval_Length_New[index] = S_Interval_Length[thread_id];
        S_Length_Suffix_New[index] = S_Length_Suffix[thread_id];

    }
}


__global__ void Compute_S5(int* S_Interval_Length_Final, int* S_Length_Suffix, int* Prefix_Sum, int size_S) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_S) {

        Prefix_Sum[thread_id] = (S_Length_Suffix[thread_id] > W) ? S_Interval_Length_Final[thread_id] + 1 : 0;
    }


}

__global__ void Compute_S6(int* S_L, int* S_Interval_Length, int* S_Length_Suffix, unsigned char* Dev_Input, unsigned char* Dev_Output, int* Prefix_Sum1, int* Prefix_Sum2, int* D, int size_S, int size_Dev_Input, int size_D) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_S) {

        int index_val12 = S_Length_Suffix[thread_id];

        if (index_val12 > W) {
            int l = S_L[thread_id];
            int r = l + S_Interval_Length[thread_id];

            int index_val11 = D[l];
            int index_val21 = D[r];
            int index_val22 = index_val12;

            int offset = ((thread_id > 0) ? Prefix_Sum1[thread_id - 1] : 0);

            index_val11 = ((index_val11 - index_val12 >= 0) ? index_val11 - index_val12 : size_Dev_Input - W - 1);
            index_val21 = ((index_val21 - index_val22 >= 0) ? index_val21 - index_val22 : size_Dev_Input - W - 1);

            unsigned char char_val1 = Dev_Input[index_val11];
            unsigned char char_val2 = Dev_Input[index_val21];
            Prefix_Sum2[thread_id] = char_val1 != char_val2;

            if (char_val1 == char_val2) {

                r -= l;
                l = offset;
                r += offset;

                Dev_Output[l] = char_val1;

                //for (int i = l; i <= r; i++) {
                    //Dev_Output[i] = char_val1;

                //}
            }

        }
        else
            Prefix_Sum2[thread_id] = 0;
    }

}


__global__ void Compute_Suffixes_Without_Same_Preeceding_Char1(int* Suffixe_Group_Offset, int* S_L, int* S_Interval_Length, int* S_Length_Suffix, int* Suffixes_Without_Same_Preeceding_Char, int* Prefix_Sum1, int* Prefix_Sum2, int size_S, int size_Suffixes_Without_Same_Preeceding_Char) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_S) {

        int offset1 = ((thread_id > 0) ? Prefix_Sum1[thread_id - 1] : 0);
        int val = ((thread_id > 0) ? Prefix_Sum1[thread_id] - offset1 : Prefix_Sum1[0]);
        int offset2 = ((thread_id > 0) ? Prefix_Sum2[thread_id - 1] : 0);
        if (val > 0) {
            int l = S_L[thread_id];
            Suffixes_Without_Same_Preeceding_Char[offset1] = l;//l
            Suffixes_Without_Same_Preeceding_Char[offset1 + size_Suffixes_Without_Same_Preeceding_Char] = S_Length_Suffix[thread_id];//length_suffix
            Suffixes_Without_Same_Preeceding_Char[offset1 + 2 * size_Suffixes_Without_Same_Preeceding_Char] = offset2;//offset_bwt_insert
            Suffixe_Group_Offset[offset1 + 1] = S_Interval_Length[thread_id] + 1;//r
        }
        if (thread_id == 0)
            Suffixe_Group_Offset[0] = 0;

    }

}

__global__ void Compute_Suffixes_Without_Same_Preeceding_Char2(int* Suffixe_Group_Offset, int* Sort_Chunk_Prefix_Sum, int size_Suffixes_Without_Same_Preeceding_Char, int max_size_group) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_Suffixes_Without_Same_Preeceding_Char) {

        if (thread_id == size_Suffixes_Without_Same_Preeceding_Char - 1)
            Sort_Chunk_Prefix_Sum[size_Suffixes_Without_Same_Preeceding_Char - 1] = 1;
        else {
            int val1 = Suffixe_Group_Offset[thread_id + 1];
            int val2 = Suffixe_Group_Offset[thread_id + 2];
            int group_size = val2 - val1;
            if (group_size >= max_size_group)
                Sort_Chunk_Prefix_Sum[thread_id] = 1;
            else {
                int group_size_div1 = val1 / max_size_group;
                int group_size_div2 = val2 / max_size_group;
                Sort_Chunk_Prefix_Sum[thread_id] = group_size_div1 < group_size_div2;
            }
        }
    }
}

__global__ void Compute_Suffixes_Without_Same_Preeceding_Char3(int* Suffixe_Group_Offset, int* Sort_Chunk_Prefix_Sum, int* Dev_CPU_Blocks_Array, int* Dev_CPU_Blocks_Array1, int size_Suffixes_Without_Same_Preeceding_Char) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_Suffixes_Without_Same_Preeceding_Char) {
        int index = Sort_Chunk_Prefix_Sum[thread_id];
        bool cond = (thread_id == 0 && index > 0) || (thread_id > 0 && index > Sort_Chunk_Prefix_Sum[thread_id - 1]);
        if (cond) {
            index--;
            Dev_CPU_Blocks_Array[index] = thread_id + 1;
            Dev_CPU_Blocks_Array1[index] = Suffixe_Group_Offset[thread_id + 1];
        }
    }
}

__global__ void Compute_Suffixes_Without_Same_Preeceding_Char4(int* Suffixe_Group_Offset, int* Prefix_Sum1, int l, int l1, int r) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < r) {

        int offset1 = Suffixe_Group_Offset[thread_id + l] - l1;
        Suffixe_Group_Offset[thread_id + l] = offset1;
        if (thread_id == r - 1) {
            Suffixe_Group_Offset[thread_id + 1 + l] -= l1;
        }
        Prefix_Sum1[offset1] = 1;

    }

}

__global__ void Compute_Suffixes_Without_Same_Preeceding_Char4_1(int* Suffixe_Group_Offset, int* Prefix_Sum1, int l, int l1, int r) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < r) {

        int offset1 = Suffixe_Group_Offset[thread_id + l];
        if (thread_id == r - 1) {
            Suffixe_Group_Offset[thread_id + 1 + l] += l1;
        }
        Prefix_Sum1[offset1] = 1;

    }

}

__global__ void Compute_Suffixes_Without_Same_Preeceding_Char5(unsigned char* Dev_Input, unsigned char* Insert_Characters, int* D, int* Suffixe_Group_Offset, int* Suffixes_Without_Same_Preeceding_Char, int* Prefix_Sum1, int* Suffixe_Ranks, int l, int r, int size_Dev_Input, int size_D, int size_Suffixes_Without_Same_Preeceding_Char) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < r) {

        int index = Prefix_Sum1[thread_id] - 1;
        int in_group_index = thread_id - (Suffixe_Group_Offset[index + l]);
        int d_begin_area = Suffixes_Without_Same_Preeceding_Char[index + l];
        int d_index = d_begin_area + in_group_index;
        int length_suffix = Suffixes_Without_Same_Preeceding_Char[index + l + size_Suffixes_Without_Same_Preeceding_Char];

        int pos_D = D[d_index];

        int suffix_rank = (D[d_index + 2 * size_D]);

        int index_preeceding_characte_suffix = ((pos_D - length_suffix >= 0) ? pos_D - length_suffix : size_Dev_Input - W - 1);
        unsigned char preeceding_characte_suffix = Dev_Input[index_preeceding_characte_suffix];

        Suffixe_Ranks[thread_id] = suffix_rank;
        Insert_Characters[thread_id] = preeceding_characte_suffix;
    }


}

__global__ void Compute_Suffixes_Without_Same_Preeceding_Char6(int* Suffixe_Ranks, int* Suffixe_Group_Offset, unsigned char* Dev_Output, unsigned char* Insert_Characters, int* Suffixes_Without_Same_Preeceding_Char, int* Prefix_Sum1, int size_Suffixes_Without_Same_Preeceding_Char, int l, int r) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < r) {

        int index = Prefix_Sum1[thread_id] - 1;
        int in_group_index = thread_id - (Suffixe_Group_Offset[index + l]);
        int bwt_index = in_group_index + Suffixes_Without_Same_Preeceding_Char[index + l + 2 * size_Suffixes_Without_Same_Preeceding_Char];

        Dev_Output[bwt_index] = Insert_Characters[thread_id];

    }

}

__global__ void Init_S_Key_And_S_Value_In(int2* S_Values_In, unsigned long long* S_Key, int* S_L, int* D, int* S_Length, unsigned char* Dev_Input, int size_S_Sorting) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_S_Sorting) {
        unsigned char prefix_thread[8];
        int D_index = S_L[thread_id];
        int suffix_end = D[D_index];
        int index = suffix_end - S_Length[thread_id] + 1;
        for (int j = 0; j < 8; j++, index++)
            prefix_thread[j] = ((index <= suffix_end) ? Dev_Input[index] : 0);

        S_Key[thread_id] = pack8(prefix_thread);
        S_Values_In[thread_id].x = thread_id;
        S_Values_In[thread_id].y = 0;
    }
}

__global__ void Init_S_Ranks(int* S_Pointer_Jumping1, int* S_Ranks_Final, int2* S_Values_In, int* S_Lenght, int* Prefix_Sum1, unsigned long long* S_Key, int size_S_Sorting, int prefix_length) {
    int thread_id = threadIdx.x + blockDim.x * blockIdx.x;
    if (thread_id < size_S_Sorting) {

        int index = S_Values_In[thread_id].x;

        S_Key[thread_id] = ((S_Lenght[index] > prefix_length) ? S_Ranks_Final[S_Pointer_Jumping1[index]] + 1 : 0) | (((unsigned long long)S_Values_In[thread_id].y) << 32);

    }
}

void Sort_S(int* S_Pointer_Jumping1, int* S_Pointer_Jumping2, int* S_Mem2) {

    int size_S_Sorting = size_S;
    int num_blocks_size_S_Sorting = num_blocks_size_S;
    int prefix_length = 8;

    int2* S_Values_In;
    int2* S_Values_Out;
    unsigned long long* S_Key;
    unsigned long long* S_Key_New;

    int* S_Ranks_Final;

    int* S_Mem1;

    cudaMalloc((void**)&S_Mem1, (4 * size_S_Sorting) * sizeof(int));

    S_Values_In = (int2*)S_Mem1;
    S_Values_Out = (int2*)(S_Mem2);
    S_Key = (unsigned long long*)(S_Mem1 + size_S_Sorting * 2);
    S_Key_New = (unsigned long long*)(Auxiliar1);
    S_Ranks_Final = S_Mem2 + 2 * size_S_Sorting;

    Init_S_Key_And_S_Value_In << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Values_In, S_Key, S_L, D, S_Length_Suffix, Dev_Input, size_S_Sorting);

    size_t   temp_storage_bytes = 0;
    SegmentedSort_bytes = 0;

    int* Prefix_Sum1 = (int*)S_Key;
    int* Prefix_Sum2 = (int*)S_Key_New;
    while (size_S_Sorting > 0) {

        cub::DeviceRadixSort::SortPairs(
            nullptr, temp_storage_bytes,
            S_Key, S_Key_New, S_Values_In, S_Values_Out, size_S_Sorting);

        if (temp_storage_bytes > SegmentedSort_bytes) {

            if (SegmentedSort_bytes > 0)
                cudaFree(SegmentedSort_Temp_Storage);

            SegmentedSort_bytes = temp_storage_bytes;

            cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
        }

        cub::DeviceRadixSort::SortPairs(
            SegmentedSort_Temp_Storage, temp_storage_bytes,
            S_Key, S_Key_New, S_Values_In, S_Values_Out, size_S_Sorting);

        swap(S_Values_In, S_Values_Out);

        Reduce_D_0 << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Key_New, Prefix_Sum1, size_S_Sorting);

        Reduce_Parse_1 << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Values_In, Prefix_Sum1, Prefix_Sum2, size_S_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_S_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum2),
            thrust::device_pointer_cast(Prefix_Sum2 + size_S_Sorting),
            thrust::device_pointer_cast(Prefix_Sum2)
        );
        int* Prefix_Sum3 = (int*)S_Values_Out;
        int* Prefix_Sum4 = Prefix_Sum3 + size_S_Sorting;

        Reduce_D_2 << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_S_Sorting);

        Reduce_Parse_3 << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Values_In, Prefix_Sum1, Prefix_Sum2, Prefix_Sum3, Prefix_Sum4, size_S_Sorting);

        Reduce_Parse_4 << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Values_In, Prefix_Sum1, Prefix_Sum2, size_S_Sorting);

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Prefix_Sum1),
            thrust::device_pointer_cast(Prefix_Sum1 + size_S_Sorting),
            thrust::device_pointer_cast(Prefix_Sum1)
        );

        int size_S_Sorting_New;
        cudaMemcpy(&size_S_Sorting_New, Prefix_Sum1 + size_S_Sorting - 1, sizeof(int), cudaMemcpyDeviceToHost);
        int num_blocks_size_S_Sorting_New = (size_S_Sorting_New + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;
        //printf("\n%d",size_S_Sorting_New);
        Reduce_Parse_6 << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Ranks_Final, S_Values_In, S_Values_Out, Prefix_Sum1, size_S_Sorting);

        swap(S_Values_In, S_Values_Out);

        size_S_Sorting = size_S_Sorting_New;
        num_blocks_size_S_Sorting = num_blocks_size_S_Sorting_New;

        if (size_S_Sorting == 0)
            break;


        Init_S_Ranks << < num_blocks_size_S_Sorting, MAX_THREADS_PER_BLOCK >> > (S_Pointer_Jumping1, S_Ranks_Final, S_Values_In, S_Length_Suffix, Prefix_Sum1, S_Key, size_S_Sorting, prefix_length);

        prefix_length <<= 1;

        Pointer_Jumping_S_Kernel2 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (S_Pointer_Jumping2, S_Pointer_Jumping1, S_Length_Suffix, prefix_length, size_S);

        swap(S_Pointer_Jumping1, S_Pointer_Jumping2);

    }

    cudaMemcpy(Auxiliar1, S_Ranks_Final, (size_S) * sizeof(int), cudaMemcpyDeviceToDevice);

    cudaFree(S_Mem1);
    cudaFree(SegmentedSort_Temp_Storage);

}


void Compute_S() {


    int smallest_two_potenz_larger_than_size_D = smallest_two_potenz_larger_than_k(size_D);
    int size_L_Values_Min_Tree = smallest_two_potenz_larger_than_size_D * 2;

    cudaMalloc((void**)&Auxiliar1, size_D * sizeof(int));
    cudaMalloc((void**)&Auxiliar2, size_L_Values_Min_Tree * sizeof(int));
    int* Prefix_Sum1 = (int*)Auxiliar1;
    int* L_Values_Min_Tree = (int*)Auxiliar2;
    int* L_Values = L_Values_Min_Tree + smallest_two_potenz_larger_than_size_D;

    Compute_S1 << <num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (D, Dev_Input, Prefix_Sum1, L_Values, size_D);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(Prefix_Sum1),
        thrust::device_pointer_cast(Prefix_Sum1 + size_D),
        thrust::device_pointer_cast(Prefix_Sum1)
    );

    cudaMemcpy(&size_S, Prefix_Sum1 + (size_D - 1), sizeof(int), cudaMemcpyDeviceToHost);



    if (smallest_two_potenz_larger_than_size_D - size_D > 0)
        Init_Vector1 << < (smallest_two_potenz_larger_than_size_D - size_D + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK, MAX_THREADS_PER_BLOCK >> > (L_Values_Min_Tree, smallest_two_potenz_larger_than_size_D - size_D, INT_MAX, size_D + smallest_two_potenz_larger_than_size_D);

    for (int num_nodes = smallest_two_potenz_larger_than_size_D >> 1; num_nodes > 0; num_nodes >>= 1) {

        Compute_L_Values_Min_Tree << < (num_nodes + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK, MAX_THREADS_PER_BLOCK >> > (L_Values_Min_Tree, num_nodes, num_nodes);
    }


    int* S_Pointer_Jumping1;


    cudaMalloc((void**)&S_L, (size_S) * sizeof(int));
    cudaMalloc((void**)&S_Interval_Length, (size_S) * sizeof(int));
    cudaMalloc((void**)&S_Length_Suffix, (size_S) * sizeof(int));
    cudaMalloc((void**)&S_Pointer_Jumping1, (size_S) * sizeof(int));

    num_blocks_size_S = (size_S + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

    Compute_S2 << <num_blocks_size_D, MAX_THREADS_PER_BLOCK >> > (S_Pointer_Jumping1, S_L, S_Length_Suffix, S_Interval_Length, D, Prefix_Sum1, L_Values_Min_Tree, size_D, size_S, smallest_two_potenz_larger_than_size_D);

    cudaFree(Auxiliar1);
    cudaFree(Auxiliar2);

    int* S_Pointer_Jumping2;
    int* S_Mem2;

    cudaMalloc((void**)&Auxiliar1, (2 * size_S) * sizeof(int));
    cudaMalloc((void**)&S_Mem2, (3 * size_S) * sizeof(int));
    cudaMalloc((void**)&S_Pointer_Jumping2, (size_S) * sizeof(int));

    Auxiliar2 = Auxiliar1 + size_S;

    Pointer_Jumping_S_Kernel2 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (S_Pointer_Jumping2, S_Pointer_Jumping1, S_Length_Suffix, 1, size_S);

    swap(S_Pointer_Jumping1, S_Pointer_Jumping2);

    Pointer_Jumping_S_Kernel2 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (S_Pointer_Jumping2, S_Pointer_Jumping1, S_Length_Suffix, 2, size_S);

    swap(S_Pointer_Jumping1, S_Pointer_Jumping2);

    Pointer_Jumping_S_Kernel2 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (S_Pointer_Jumping2, S_Pointer_Jumping1, S_Length_Suffix, 4, size_S);

    swap(S_Pointer_Jumping1, S_Pointer_Jumping2);

    Sort_S(S_Pointer_Jumping1, S_Pointer_Jumping2, S_Mem2);

    int* S_L_New = S_Mem2;
    int* S_Interval_Length_New = S_Mem2 + size_S;
    int* S_Length_Suffix_New = S_Mem2 + 2 * size_S;

    Reduce_S_5 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (Auxiliar1, S_L, S_Interval_Length, S_Length_Suffix, S_L_New, S_Interval_Length_New, S_Length_Suffix_New, size_S);

    cudaFree(S_L);
    cudaFree(S_Interval_Length);
    cudaFree(S_Length_Suffix);
    cudaFree(S_Pointer_Jumping1);
    cudaFree(S_Pointer_Jumping2);

    S_L = S_L_New;
    S_Interval_Length = S_Interval_Length_New;
    S_Length_Suffix = S_Length_Suffix_New;

    Compute_S5 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (S_Interval_Length, S_Length_Suffix, Auxiliar1, size_S);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(Auxiliar1),
        thrust::device_pointer_cast(Auxiliar1 + size_S),
        thrust::device_pointer_cast(Auxiliar1)
    );

    Compute_S6 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (S_L, S_Interval_Length, S_Length_Suffix, Dev_Input, Dev_Output, Auxiliar1, Auxiliar2, D, size_S, n_enlarged, size_D);

    thrust::inclusive_scan(
        thrust::device_pointer_cast(Auxiliar2),
        thrust::device_pointer_cast(Auxiliar2 + size_S),
        thrust::device_pointer_cast(Auxiliar2)
    );

    cudaMemcpy(&size_Suffixes_Without_Same_Preeceding_Char, Auxiliar2 + (size_S - 1), sizeof(int), cudaMemcpyDeviceToHost);
    if (size_Suffixes_Without_Same_Preeceding_Char > 0) {

        num_blocks_size_Suffixes_Without_Same_Preeceding_Char = (size_Suffixes_Without_Same_Preeceding_Char + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

        int* Suffixe_Group_Offset;
        int* Sort_Chunk_Prefix_Sum;
        cudaMalloc((void**)&Suffixes_Without_Same_Preeceding_Char, (size_Suffixes_Without_Same_Preeceding_Char * 3) * sizeof(int));
        cudaMalloc((void**)&Suffixe_Group_Offset, (size_Suffixes_Without_Same_Preeceding_Char + 1) * sizeof(int));
        cudaMalloc((void**)&Sort_Chunk_Prefix_Sum, (size_Suffixes_Without_Same_Preeceding_Char) * sizeof(int));

        Compute_Suffixes_Without_Same_Preeceding_Char1 << <num_blocks_size_S, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Offset, S_L, S_Interval_Length, S_Length_Suffix, Suffixes_Without_Same_Preeceding_Char, Auxiliar2, Auxiliar1, size_S, size_Suffixes_Without_Same_Preeceding_Char);
        cudaFree(Auxiliar1);
        cudaFree(S_Mem2);

        thrust::sort_by_key(
            thrust::device_pointer_cast(Suffixe_Group_Offset + 1),
            thrust::device_pointer_cast(Suffixe_Group_Offset + size_Suffixes_Without_Same_Preeceding_Char + 1),
            thrust::make_zip_iterator(thrust::make_tuple(thrust::device_pointer_cast(Suffixes_Without_Same_Preeceding_Char), thrust::device_pointer_cast(Suffixes_Without_Same_Preeceding_Char + size_Suffixes_Without_Same_Preeceding_Char), thrust::device_pointer_cast(Suffixes_Without_Same_Preeceding_Char + 2 * size_Suffixes_Without_Same_Preeceding_Char)))
        );

        int max_size_group;
        cudaMemcpy(&max_size_group, Suffixe_Group_Offset + size_Suffixes_Without_Same_Preeceding_Char, sizeof(int), cudaMemcpyDeviceToHost);
        if (n <= 10) {
            max_size_group = n;
        }
        else {
            if (max_size_group < n / 20)
                max_size_group = n / 20;
        }

        int max_mem_group = max_size_group * 2;

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Suffixe_Group_Offset),
            thrust::device_pointer_cast(Suffixe_Group_Offset + size_Suffixes_Without_Same_Preeceding_Char + 1),
            thrust::device_pointer_cast(Suffixe_Group_Offset)
        );

        Compute_Suffixes_Without_Same_Preeceding_Char2 << <num_blocks_size_Suffixes_Without_Same_Preeceding_Char, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Offset, Sort_Chunk_Prefix_Sum, size_Suffixes_Without_Same_Preeceding_Char, max_size_group);

        int* Dev_CPU_Blocks_Array;
        int* CPU_Blocks_Array;
        int* Dev_CPU_Blocks_Array1;
        int* CPU_Blocks_Array1;

        int size_CPU_Blocks_Array;

        thrust::inclusive_scan(
            thrust::device_pointer_cast(Sort_Chunk_Prefix_Sum),
            thrust::device_pointer_cast(Sort_Chunk_Prefix_Sum + size_Suffixes_Without_Same_Preeceding_Char),
            thrust::device_pointer_cast(Sort_Chunk_Prefix_Sum)
        );

        cudaMemcpy(&size_CPU_Blocks_Array, Sort_Chunk_Prefix_Sum + size_Suffixes_Without_Same_Preeceding_Char - 1, sizeof(int), cudaMemcpyDeviceToHost);

        cudaMalloc((void**)&Dev_CPU_Blocks_Array, (size_CPU_Blocks_Array) * sizeof(int));
        cudaMalloc((void**)&Dev_CPU_Blocks_Array1, (size_CPU_Blocks_Array) * sizeof(int));
        CPU_Blocks_Array = new int[size_CPU_Blocks_Array];
        CPU_Blocks_Array1 = new int[size_CPU_Blocks_Array];

        Compute_Suffixes_Without_Same_Preeceding_Char3 << <num_blocks_size_Suffixes_Without_Same_Preeceding_Char, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Offset, Sort_Chunk_Prefix_Sum, Dev_CPU_Blocks_Array, Dev_CPU_Blocks_Array1, size_Suffixes_Without_Same_Preeceding_Char);

        cudaMemcpy(CPU_Blocks_Array, Dev_CPU_Blocks_Array, size_CPU_Blocks_Array * sizeof(int), cudaMemcpyDeviceToHost);
        cudaMemcpy(CPU_Blocks_Array1, Dev_CPU_Blocks_Array1, size_CPU_Blocks_Array * sizeof(int), cudaMemcpyDeviceToHost);


        int* Suffixe_Ranks;
        int* Suffixe_Group_Indicator;
        unsigned char* Insert_Characters;
        unsigned char* Insert_Characters_New;

        cudaMalloc((void**)&Suffixe_Ranks, (max_mem_group) * sizeof(int));
        cudaMalloc((void**)&Suffixe_Group_Indicator, (max_mem_group) * sizeof(int));
        cudaMalloc((void**)&Insert_Characters, (max_mem_group) * sizeof(unsigned char));
        cudaMalloc((void**)&Insert_Characters_New, (max_mem_group) * sizeof(unsigned char));

        int l = 0;
        int l1 = 0;
        int r = CPU_Blocks_Array[0];
        int r1 = CPU_Blocks_Array1[0];

        SegmentedSort_bytes = 0;

        for (int round = 0; round < size_CPU_Blocks_Array; round++) {

            int diff = r - l;
            int diff1 = r1 - l1;

            int num_blocks_l = (diff + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;
            int num_blocks_l1 = (diff1 + MAX_THREADS_PER_BLOCK - 1) / MAX_THREADS_PER_BLOCK;

            Init_Vector << <num_blocks_l1, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Indicator, diff1, 0);

            Compute_Suffixes_Without_Same_Preeceding_Char4 << <num_blocks_l, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Offset, Suffixe_Group_Indicator, l, l1, diff);

            thrust::inclusive_scan(
                thrust::device_pointer_cast(Suffixe_Group_Indicator),
                thrust::device_pointer_cast(Suffixe_Group_Indicator + diff1),
                thrust::device_pointer_cast(Suffixe_Group_Indicator)
            );

            Compute_Suffixes_Without_Same_Preeceding_Char5 << <num_blocks_l1, MAX_THREADS_PER_BLOCK >> > (Dev_Input, Insert_Characters, D, Suffixe_Group_Offset, Suffixes_Without_Same_Preeceding_Char, Suffixe_Group_Indicator, Suffixe_Ranks, l, diff1, n_enlarged, size_D, size_Suffixes_Without_Same_Preeceding_Char);

            if (diff > 1) {

                size_t   temp_storage_bytes = 0;
                cub::DeviceSegmentedSort::SortPairs(
                    nullptr, temp_storage_bytes,
                    Suffixe_Ranks, Suffixe_Group_Indicator, Insert_Characters, Insert_Characters_New,
                    diff1, diff, Suffixe_Group_Offset + l, Suffixe_Group_Offset + l + 1);

                if (temp_storage_bytes > SegmentedSort_bytes) {

                    if (SegmentedSort_bytes > 0)
                        cudaFree(SegmentedSort_Temp_Storage);

                    SegmentedSort_bytes = temp_storage_bytes;

                    cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
                }

                cub::DeviceSegmentedSort::SortPairs(
                    SegmentedSort_Temp_Storage, temp_storage_bytes,
                    Suffixe_Ranks, Suffixe_Group_Indicator, Insert_Characters, Insert_Characters_New,
                    diff1, diff, Suffixe_Group_Offset + l, Suffixe_Group_Offset + l + 1);
            }
            else {

                size_t   temp_storage_bytes = 0;
                cub::DeviceRadixSort::SortPairs(
                    nullptr, temp_storage_bytes,
                    Suffixe_Ranks, Suffixe_Group_Indicator, Insert_Characters, Insert_Characters_New,
                    diff1);

                if (temp_storage_bytes > SegmentedSort_bytes) {

                    if (SegmentedSort_bytes > 0)
                        cudaFree(SegmentedSort_Temp_Storage);

                    SegmentedSort_bytes = temp_storage_bytes;

                    cudaMalloc(&SegmentedSort_Temp_Storage, SegmentedSort_bytes);
                }

                cub::DeviceRadixSort::SortPairs(
                    SegmentedSort_Temp_Storage, temp_storage_bytes,
                    Suffixe_Ranks, Suffixe_Group_Indicator, Insert_Characters, Insert_Characters_New,
                    diff1);
            }

            Init_Vector << <num_blocks_l1, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Indicator, diff1, 0);

            Compute_Suffixes_Without_Same_Preeceding_Char4_1 << <num_blocks_l, MAX_THREADS_PER_BLOCK >> > (Suffixe_Group_Offset, Suffixe_Group_Indicator, l, l1, diff);

            thrust::inclusive_scan(
                thrust::device_pointer_cast(Suffixe_Group_Indicator),
                thrust::device_pointer_cast(Suffixe_Group_Indicator + diff1),
                thrust::device_pointer_cast(Suffixe_Group_Indicator)
            );

            Compute_Suffixes_Without_Same_Preeceding_Char6 << <num_blocks_l1, MAX_THREADS_PER_BLOCK >> > (Suffixe_Ranks, Suffixe_Group_Offset, Dev_Output, Insert_Characters_New, Suffixes_Without_Same_Preeceding_Char, Suffixe_Group_Indicator, size_Suffixes_Without_Same_Preeceding_Char, l, diff1);

            l = r;
            l1 = r1;
            if (round + 1 < size_CPU_Blocks_Array) {
                r = CPU_Blocks_Array[round + 1];
                r1 = CPU_Blocks_Array1[round + 1];
            }
        }


        cudaFree(Suffixe_Group_Indicator);
        cudaFree(Suffixe_Ranks);
        cudaFree(Insert_Characters);
        cudaFree(Insert_Characters_New);
        cudaFree(Suffixe_Group_Offset);
        cudaFree(Sort_Chunk_Prefix_Sum);
        cudaFree(Suffixes_Without_Same_Preeceding_Char);

        cudaFree(Dev_CPU_Blocks_Array);
        cudaFree(Dev_CPU_Blocks_Array1);
        cudaFree(SegmentedSort_Temp_Storage);

        delete[] CPU_Blocks_Array;
        delete[] CPU_Blocks_Array1;
    }

}

struct Fill255
{
    __device__
        unsigned char operator()(unsigned char a, unsigned char b) const
    {
        return (b == 255) ? a : b;
    }
};

void print_Output() {

    cudaFree(Dev_Input);
    /*
    if (size_alphabet == 3) {
        printf("%d\n", n);
        for (int i = 0; i < n; i++)
            printf("%d", (Letter_Back_Transform_CPU[input[i]]));

        return;
    }
    */

    if (size_alphabet == 3) {
        FILE* f = fopen("out.txt", "w");
        fprintf(f, "%d\n", n);
        for (int i = 0; i < n; i++)
            fprintf(f, "%d ", input[i]);

        return;
    }

    thrust::inclusive_scan(
        thrust::device_pointer_cast(Dev_Output),
        thrust::device_pointer_cast(Dev_Output + n),
        thrust::device_pointer_cast(Dev_Output),
        Fill255{}
    );

    Transform_Input << <num_blocks_N, MAX_THREADS_PER_BLOCK >> > (Dev_Output, n, Letter_Back_Transform_Dev);

    cudaMemcpy(output, Dev_Output, (n + 1) * sizeof(unsigned char), cudaMemcpyDeviceToHost);

    
    FILE* f = fopen("out.txt", "w");
    fprintf(f, "%d\n", n);
    for (int i = 0; i < n; i++)
        fprintf(f, "%d ", (output[i]));
    
    /*
    FILE* f = fopen("out.txt", "w");
    fprintf(f, "%d\n", n);
    fprintf(f, "%s", output);
*/
    cudaFree(Dev_Output);
    cudaFree(Letter_Back_Transform_Dev);

    delete[] output;
    delete[] input;

}


int main()
{

    int device;
    cudaGetDevice(&device);

    struct cudaDeviceProp props;
    cudaGetDeviceProperties(&props, device);

    Scan_input();

    Compute_Params();

    Malloc_And_Copy_On_GPU();

    Remap_Letters();

    if (size_alphabet > 3) {

        Compute_D();

        Compute_S();
    }

    print_Output();

    return 0;
}

