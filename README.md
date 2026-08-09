# GPU Prefix-Free Parsing for BWT

This repository contains a CUDA implementation of the **Prefix-Free Parsing (PFP)** algorithm for the parallel construction of the **Burrows-Wheeler Transform (BWT)** on GPUs.

The implementation is designed for large and highly repetitive texts and uses CUDA, CUB, and Thrust for parallel processing, sorting, and prefix-sum operations.

## Usage

The program automatically reads the input from `input.txt` and writes the resulting BWT to `out.txt`.

Run the program with:

```bash
./Prefix_Free_Parsing
```

### Input Format

The first value in `input.txt` specifies the length of the input text. The following values contain the individual characters of the text, separated by whitespace.

For example:

```text
5

2 4 1 4 2
```

Here, `5` specifies that the text consists of five characters:

```text
2 4 1 4 2
```

The program processes the input on the GPU and writes the resulting BWT to `out.txt`.

## Performance

The implementation was evaluated on an **NVIDIA RTX 2060 Super** using repetitive text datasets from the Pizza&Chili corpus.

Compared with the previous GPU implementation (version from masterthesis), the new implementation achieves:

* **3.39× average speedup** across the test cases
* **3.16× speedup** based on the sum of all measured runtimes
* Total runtime reduced from **37.57 s to 11.88 s**
* **14.9% reduction in total GPU memory consumption**

Across all test cases, the new implementation requires approximately **31.6% of the runtime** of the previous implementation while using approximately **85.1% of its memory**.
