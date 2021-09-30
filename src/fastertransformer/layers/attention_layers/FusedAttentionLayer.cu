/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "src/fastertransformer/layers/attention_layers/FusedAttentionLayer.h"

namespace fastertransformer {

__global__ void trt_add_QKV_bias(half2* qkv_buf,
                                 const half2* Q,
                                 const half2* bias_Q,
                                 const half2* K,
                                 const half2* bias_K,
                                 const half2* V,
                                 const half2* bias_V,
                                 const int valid_word_num,
                                 const int head_num,
                                 const int size_per_head)
{
    // Add bias, and then transpose from
    // [3, valid_word_num, head, size] -> [valid_word_num, head, 3, size]

    // const int seq_id = blockIdx.x % valid_word_num;
    // const int qkv_id = (blockIdx.x - seq_id) / valid_word_num;
    const int seq_id = blockIdx.x;
    const int size_id = threadIdx.x % size_per_head;
    const int head_id = (threadIdx.x - size_id) / size_per_head;

    const int target_offset = blockIdx.x * head_num * 3 * size_per_head + head_id * 3 * size_per_head;

    qkv_buf[target_offset + 0 * size_per_head + size_id] = Q[seq_id * blockDim.x + threadIdx.x] + bias_Q[threadIdx.x];

    qkv_buf[target_offset + 1 * size_per_head + size_id] = K[seq_id * blockDim.x + threadIdx.x] + bias_K[threadIdx.x];

    qkv_buf[target_offset + 2 * size_per_head + size_id] = V[seq_id * blockDim.x + threadIdx.x] + bias_V[threadIdx.x];
}

template<typename T>
void FusedAttentionLayer<T>::invokeTrtAddQkvBias(size_t token_num, const AttentionWeight<T>* attention_weights)
{
    dim3 grid(token_num);
    dim3 block(head_num_ * size_per_head_ / 2);

    assert(block.x <= 1024);

    trt_add_QKV_bias<<<grid, block, 0, stream_>>>((half2*)qkv_buf_,
                                                  (const half2*)q_buf_,
                                                  (const half2*)attention_weights->query_weight.bias,
                                                  (const half2*)k_buf_,
                                                  (const half2*)attention_weights->key_weight.bias,
                                                  (const half2*)v_buf_,
                                                  (const half2*)attention_weights->value_weight.bias,
                                                  token_num,
                                                  head_num_,
                                                  size_per_head_ / 2);
}

template<typename T>
void FusedAttentionLayer<T>::forward(std::vector<fastertransformer::Tensor>* output_tensors,
                                     const std::vector<fastertransformer::Tensor>* input_tensors,
                                     const AttentionWeight<T>* attention_weights)
{
    // input_tensors: [input_query (token_num, hidden_dimension),
    //                 attention_mask (batch, 1, seqlen, seqlen),
    //                 padding_offset (batch + 1 or batch * 2 + 1))]
    // If padding_offset.data is nullptr, then not remove padding

    FT_CHECK(isValidBatchSize(input_tensors->at(1).shape[0]));
    FT_CHECK(isValidSeqLen(input_tensors->at(1).shape[2]));
    allocateBuffer();

    T* attention_out = (T*)output_tensors->at(0).data;
    const T* from_tensor = (const T*)input_tensors->at(0).data;
    const T* attention_mask = (const T*)input_tensors->at(1).data;
    const int* padding_offset = (const int*)input_tensors->at(2).data;

    const int request_batch_size = input_tensors->at(1).shape[0];
    const int request_seq_len = input_tensors->at(1).shape[2];
    size_t m_tmp = input_tensors->at(0).shape[0];
    if (m_tmp % 8 != 0) {
        m_tmp = (m_tmp / 8 + 1) * 8;
    }
    const size_t m = input_tensors->at(0).shape[0];
    const int k = hidden_units_;
    const int n = hidden_units_;

#ifdef SPARSITY_ENABLED
    const size_t m_padded = m_tmp;
    if (sparse_ && cublas_wrapper_->isUseSparse(1, n, m, k)) {
        cublas_wrapper_->SpGemm(
            CUBLAS_OP_N, CUBLAS_OP_N, n, m_padded, k, attention_weights->query_weight.sp_kernel, from_tensor, q_buf_);
        cublas_wrapper_->SpGemm(
            CUBLAS_OP_N, CUBLAS_OP_N, n, m_padded, k, attention_weights->key_weight.sp_kernel, from_tensor, k_buf_);
        cublas_wrapper_->SpGemm(
            CUBLAS_OP_N, CUBLAS_OP_N, n, m_padded, k, attention_weights->value_weight.sp_kernel, from_tensor, v_buf_);
    }
    else {
#endif
        const bool is_batched_QKV_ = cublas_wrapper_->isFuseBatchGemm(3, n, m, k);
        if (is_batched_QKV_) {
            const T* hA[]{attention_weights->query_weight.kernel,
                          attention_weights->key_weight.kernel,
                          attention_weights->value_weight.kernel,
                          nullptr,
                          from_tensor,
                          from_tensor,
                          from_tensor,
                          nullptr,
                          q_buf_,
                          k_buf_,
                          v_buf_,
                          nullptr};
            // Note: Here, we assume the weights of each time may be different.
            // If we can preprocess these weights before inference, we can reduce the overhead
            // caused by cudaMemcpyAsync
            check_cuda_error(
                cudaMemcpyAsync((void*)batch_qkv_kernel_ptr_, hA, sizeof(T*) * 12, cudaMemcpyHostToDevice, stream_));
            cublas_wrapper_->batchedGemm(CUBLAS_OP_N,
                                         CUBLAS_OP_N,
                                         n,
                                         m,
                                         k,
                                         (const void* const*)batch_qkv_kernel_ptr_,
                                         n,
                                         (const void* const*)batch_qkv_input_ptr_,
                                         k,
                                         (void* const*)batch_qkv_buf_ptr_,
                                         n,
                                         3);
        }
        else {
            cublas_wrapper_->Gemm(CUBLAS_OP_N,
                                  CUBLAS_OP_N,
                                  n,
                                  m,
                                  k,
                                  attention_weights->query_weight.kernel,
                                  n,
                                  from_tensor,
                                  k,
                                  q_buf_,
                                  n);
            cublas_wrapper_->Gemm(
                CUBLAS_OP_N, CUBLAS_OP_N, n, m, k, attention_weights->key_weight.kernel, n, from_tensor, k, k_buf_, n);
            cublas_wrapper_->Gemm(CUBLAS_OP_N,
                                  CUBLAS_OP_N,
                                  n,
                                  m,
                                  k,
                                  attention_weights->value_weight.kernel,
                                  n,
                                  from_tensor,
                                  k,
                                  v_buf_,
                                  n);
        }
#ifdef SPARSITY_ENABLED
    }
#endif

    invokeTrtAddQkvBias(m, attention_weights);

    int S = dispatcher_fp16->getSFromMaxSeqLen(request_seq_len);
    FT_CHECK(dispatcher_fp16->isValid(S));
    const int B = input_tensors->at(2).shape[0] - 1;
    dispatcher_fp16->setup(S, B);
    dispatcher_fp16->run(qkv_buf_, nullptr, (int*)input_tensors->at(2).data, attn_workspace_, qkv_buf_2_, stream_);
    sync_check_cuda_error();

#ifdef SPARSITY_ENABLED
    if (sparse_ && cublas_wrapper_->isUseSparse(1, n, m, k)) {
        cublas_wrapper_->SpGemm(CUBLAS_OP_N,
                                CUBLAS_OP_N,
                                n,
                                m_padded,
                                k,
                                attention_weights->attention_output_weight.sp_kernel,
                                qkv_buf_2_,
                                attention_out);
    }
    else {
#endif
        cublas_wrapper_->Gemm(CUBLAS_OP_N,
                              CUBLAS_OP_N,
                              n,
                              m,
                              k,
                              attention_weights->attention_output_weight.kernel,
                              n,
                              qkv_buf_2_,
                              k,
                              attention_out,
                              n);
#ifdef SPARSITY_ENABLED
    }
#endif

    if (is_free_buffer_after_forward_ == true) {
        freeBuffer();
    }
}

template<typename T>
FusedAttentionLayer<T>::FusedAttentionLayer(size_t max_batch_size,
                                            size_t max_seq_len,
                                            size_t head_num,
                                            size_t size_per_head,
                                            int sm,
                                            float q_scaling,
                                            cudaStream_t stream,
                                            cublasMMWrapper* cublas_wrapper,
                                            IAllocator* allocator,
                                            bool is_free_buffer_after_forward,
                                            bool sparse):
    BaseAttentionLayer<T>(stream, cublas_wrapper, allocator, is_free_buffer_after_forward),
    max_batch_size_(max_batch_size),
    max_seq_len_(max_seq_len),
    head_num_(head_num),
    size_per_head_(size_per_head),
    sm_(sm),
    q_scaling_(q_scaling),
    sparse_(sparse)
{
    if ((sm_ == kSM_70 || sm_ == kSM_86 || sm_ == kSM_80 || sm_ == kSM_75 || sm_ == kSM_72) && size_per_head_ == 64)
        dispatcher_fp16.reset(new FusedMHARunnerFP16v2(head_num_, size_per_head_, sm_, q_scaling_));
    else {
        throw std::runtime_error(std::string("[FT][ERROR] FusedAttentionLayer not support \n"));
    }
    hidden_units_ = head_num_ * size_per_head_;
}

template<typename T>
FusedAttentionLayer<T>::FusedAttentionLayer(FusedAttentionLayer<T> const& attention_layer):
    BaseAttentionLayer<T>(attention_layer.stream_,
                          attention_layer.cublas_wrapper_,
                          attention_layer.allocator_,
                          attention_layer.is_free_buffer_after_forward_),
    max_batch_size_(attention_layer.max_batch_size_),
    max_seq_len_(attention_layer.max_seq_len_),
    head_num_(attention_layer.head_num_),
    size_per_head_(attention_layer.size_per_head_),
    hidden_units_(attention_layer.hidden_units_),
    sm_(attention_layer.sm_),
    q_scaling_(attention_layer.q_scaling_),
    sparse_(attention_layer.sparse_)
{
    if ((sm_ == kSM_70 || sm_ == kSM_86 || sm_ == kSM_80 || sm_ == kSM_75 || sm_ == kSM_72) && size_per_head_ == 64)
        dispatcher_fp16.reset(new FusedMHARunnerFP16v2(head_num_, size_per_head_, sm_, q_scaling_));
    else {
        throw std::runtime_error(std::string("[FT][ERROR] FusedAttentionLayer not support \n"));
    }
}

template<typename T>
FusedAttentionLayer<T>::~FusedAttentionLayer()
{
    cublas_wrapper_ = nullptr;
    freeBuffer();
}

template<typename T>
void FusedAttentionLayer<T>::allocateBuffer()
{
    if (is_allocate_buffer_ == false) {
        q_buf_ = (T*)allocator_->malloc(sizeof(T) * max_batch_size_ * max_seq_len_ * hidden_units_, false);
        k_buf_ = (T*)allocator_->malloc(sizeof(T) * max_batch_size_ * max_seq_len_ * hidden_units_, false);
        v_buf_ = (T*)allocator_->malloc(sizeof(T) * max_batch_size_ * max_seq_len_ * hidden_units_, false);
        qkv_buf_ = (T*)allocator_->malloc(sizeof(T) * 3 * max_batch_size_ * max_seq_len_ * hidden_units_, false);
        qkv_buf_2_ = (T*)allocator_->malloc(sizeof(T) * max_batch_size_ * max_seq_len_ * hidden_units_, false);
        attn_workspace_ = (T*)allocator_->malloc(dispatcher_fp16->getWorkspaceSize(), false);

        batch_qkv_kernel_ptr_ = (T**)allocator_->malloc(sizeof(T*) * 12, false);
        batch_qkv_input_ptr_ = batch_qkv_kernel_ptr_ + 4;
        batch_qkv_buf_ptr_ = batch_qkv_input_ptr_ + 4;
        is_allocate_buffer_ = true;
    }
}

template<typename T>
void FusedAttentionLayer<T>::freeBuffer()
{
    if (is_allocate_buffer_ == true) {
        allocator_->free(q_buf_);
        allocator_->free(k_buf_);
        allocator_->free(v_buf_);
        allocator_->free(qkv_buf_);
        allocator_->free(qkv_buf_2_);
        allocator_->free(attn_workspace_);

        allocator_->free(batch_qkv_kernel_ptr_);
        is_allocate_buffer_ = false;
        sync_check_cuda_error();
    }
}

template<typename T>
bool FusedAttentionLayer<T>::isValidBatchSize(size_t batch_size)
{
    if (max_batch_size_ == 0) {
        max_batch_size_ = batch_size;
        return true;
    }
    else {
        return batch_size <= max_batch_size_;
    }
}

template<typename T>
bool FusedAttentionLayer<T>::isValidSeqLen(size_t seq_len)
{
    if (max_seq_len_ == 0) {
        max_seq_len_ = seq_len;
    }
    return seq_len <= max_seq_len_ && seq_len <= 384;
}

template class FusedAttentionLayer<float>;
template class FusedAttentionLayer<half>;

}  // namespace fastertransformer