/*
* 713_Assignment 2
* In the assignment, I will implement a Automatic Contrast Enhancement algorithm with Parallel Reduction on CUDA.
*
* Algortihm and strategies are my own.
* This file contains the CUDA version of the algorithm.
*/

#include <iostream>
#include <fstream>
#include <sstream>
#include <stdio.h>
#include <stdlib.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "npp.h"
#include <windows.h>

//global variables for and function declerations for performance measurements
double PCFreq = 0.0;
__int64 CounterStart = 0;
void StartCounter();
double GetCounter();

// Function declarations.
Npp8u *
LoadPGM(char * sFileName, int & nWidth, int & nHeight, int & nMaxGray);

void
WritePGM(char * sFileName, Npp8u * pDst_Host, int nWidth, int nHeight, int nMaxGray);

__global__ void 
Min8uGPU(Npp8u * pSrc_Dev, Npp8u * pMin_Dev);

__global__ void 
Max8uGPU(Npp8u * pSrc_Dev, Npp8u * pMax_Dev);

__global__ void 
SubMin8uGPU(Npp8u * pDst_Dev, Npp8u * pSrc_Dev, Npp8u nMin_Dev);

__global__ void 
MulDiv8uGPU(Npp8u * pDst_Dev, Npp8u nConstant, int nScaleFactorMinus1);

#define DIM 512

// Main function.
int
main(int argc, char ** argv)
{
	// Host parameter declarations.	
	Npp8u * pSrc_Host, *pDst_Host;
	int   nWidth, nHeight, nMaxGray;

	std::cout << "####### CUDA VERSION #######" << std::endl;

	// Load image to the host.
	std::cout << "Load PGM file." << std::endl;
	pSrc_Host = LoadPGM("..\\input\\lena_before.pgm", nWidth, nHeight, nMaxGray);
	pDst_Host = new Npp8u[nWidth * nHeight];

	// Device parameter declarations.
	Npp8u	 * pSrc_Dev, *pDst_Dev;
	Npp8u    * pMin_Dev, *pMax_Dev;
	Npp8u    nMin_Host[DIM], nMax_Host[DIM];
	int		 nSrcStep_Dev, nDstStep_Dev;

	// Copy the image from the host to GPU
	pSrc_Dev = nppiMalloc_8u_C1(nWidth, nHeight, &nSrcStep_Dev);
	pDst_Dev = nppiMalloc_8u_C1(nWidth, nHeight, &nDstStep_Dev);
	cudaMalloc(&pMin_Dev, sizeof(Npp8u) * DIM);
	cudaMalloc(&pMax_Dev, sizeof(Npp8u) * DIM);
	std::cout << "Copy image from host to device." << std::endl;
	cudaMemcpy(pSrc_Dev, pSrc_Host, nWidth * nHeight * sizeof(Npp8u), cudaMemcpyHostToDevice);

	std::cout << "Process the image on GPU." << std::endl;

	// Compute the min and the max.
	dim3 dimGrid(nWidth);
	dim3 dimBlockHalf(nWidth / 2);
	dim3 dimBlock(nWidth);
	cudaStream_t stream1, stream2;
	cudaStreamCreate(&stream1);	cudaStreamCreate(&stream2);	size_t sharedMemSize = nWidth * sizeof(Npp8u);

	//start counter for performance mesaurements
	StartCounter();

	// Compute the min and the max.
	Min8uGPU << <dimGrid, dimBlockHalf, sharedMemSize, stream1 >> > (pSrc_Dev, pMin_Dev);
	Max8uGPU << <dimGrid, dimBlockHalf, sharedMemSize, stream2 >> > (pSrc_Dev, pMax_Dev);
	Min8uGPU << <1, dimBlockHalf, sharedMemSize, stream1 >> > (pMin_Dev, pMin_Dev);
	Max8uGPU << <1, dimBlockHalf, sharedMemSize, stream2 >> > (pMax_Dev, pMax_Dev);
	
	// get max and min to host
	cudaMemcpy(&nMin_Host, pMin_Dev, sizeof(Npp8u) * 512, cudaMemcpyDeviceToHost);
	cudaMemcpy(&nMax_Host, pMax_Dev, sizeof(Npp8u) * 512, cudaMemcpyDeviceToHost);

	// Subtract Min
	SubMin8uGPU << <dimGrid, dimBlock, 0, stream1 >> > (pDst_Dev, pSrc_Dev, nMin_Host[0]);

	// Compute the optimal nConstant and nScaleFactor for integer operation see GTC 2013 Lab NPP.pptx for explanation
	// I will prefer integer arithmetic, Instead of using 255.0f / (nMax_Host - nMin_Host) directly
	int nScaleFactor = 0;
	int nPower = 1;
	while (nPower * 255.0f / (nMax_Host[0] - nMin_Host[0]) < 255.0f)
	{
		nScaleFactor++;
		nPower *= 2;
	}
	Npp8u nConstant = static_cast<Npp8u>(255.0f / (nMax_Host[0] - nMin_Host[0]) * (nPower / 2));

	// multiply by nConstant and divide by 2 ^ nScaleFactor-1
	MulDiv8uGPU << <dimGrid, dimBlock, 0, stream1 >> > (pDst_Dev, nConstant, nScaleFactor - 1);

	std::cout << "Duration of CUDA Run: " << GetCounter() << " microseconds" << std::endl;

	// Copy result back to the host.
	std::cout << "Work done! Copy the result back to host." << std::endl;
	cudaMemcpy(pDst_Host, pDst_Dev, nWidth * nHeight * sizeof(Npp8u), cudaMemcpyDeviceToHost);

	// Output the result image.
	std::cout << "Output the PGM file." << std::endl;
	WritePGM("..\\output\\lena_after_CUDA.pgm", pDst_Host, nWidth, nHeight, nMaxGray);

	// Clean up.
	std::cout << "Clean up." << std::endl;
	delete[] pSrc_Host;
	delete[] pDst_Host;

	nppiFree(pSrc_Dev);
	nppiFree(pDst_Dev);
	cudaFree(pMin_Dev);
	cudaFree(pMax_Dev);

	return 0;
}

// Disable reporting warnings on functions that were marked with deprecated.
#pragma warning( disable : 4996 )

// Load PGM file.
Npp8u *
LoadPGM(char * sFileName, int & nWidth, int & nHeight, int & nMaxGray)
{
	char aLine[256];
	FILE * fInput = fopen(sFileName, "r");
	if (fInput == 0)
	{
		perror("Cannot open file to read");
		exit(EXIT_FAILURE);
	}
	// First line: version
	fgets(aLine, 256, fInput);
	std::cout << "\tVersion: " << aLine;
	// Second line: comment
	fgets(aLine, 256, fInput);
	std::cout << "\tComment: " << aLine;
	fseek(fInput, -1, SEEK_CUR);
	// Third line: size
	fscanf(fInput, "%d", &nWidth);
	std::cout << "\tWidth: " << nWidth;
	fscanf(fInput, "%d", &nHeight);
	std::cout << " Height: " << nHeight << std::endl;
	// Fourth line: max value
	fscanf(fInput, "%d", &nMaxGray);
	std::cout << "\tMax value: " << nMaxGray << std::endl;
	while (getc(fInput) != '\n');
	// Following lines: data
	Npp8u * pSrc_Host = new Npp8u[nWidth * nHeight];
	for (int i = 0; i < nHeight; ++i)
		for (int j = 0; j < nWidth; ++j)
			pSrc_Host[i*nWidth + j] = fgetc(fInput);
	fclose(fInput);

	return pSrc_Host;
}

// Write PGM image.
void
WritePGM(char * sFileName, Npp8u * pDst_Host, int nWidth, int nHeight, int nMaxGray)
{
	FILE * fOutput = fopen(sFileName, "w+");
	if (fOutput == 0)
	{
		perror("Cannot open file to read");
		exit(EXIT_FAILURE);
	}
	char * aComment = "# Created by NPP";
	fprintf(fOutput, "P5\n%s\n%d %d\n%d\n", aComment, nWidth, nHeight, nMaxGray);
	for (int i = 0; i < nHeight; ++i)
		for (int j = 0; j < nWidth; ++j)
			fputc(pDst_Host[i*nWidth + j], fOutput);
	fclose(fOutput);
}

//This function calculates minimum in a given array.
//since syncthreads does not work inter-blocks, i will call this function twice
//first with 512*512 element and last with 512 elements
__global__ void 
Min8uGPU(Npp8u * pSrc_Dev, Npp8u * pMin_Dev)
{
	extern __shared__ Npp8u sdata[];
	//// each thread loads one element from global to shared mem
	unsigned int tid = threadIdx.x;
	unsigned int i = blockIdx.x * (blockDim.x * 2) + threadIdx.x;
	if (pSrc_Dev[i] > pSrc_Dev[i + blockDim.x])
	{
		sdata[tid] = pSrc_Dev[i + blockDim.x];
	}
	else
	{
		sdata[tid] = pSrc_Dev[i];
	}
	__syncthreads();

	for (unsigned int s = blockDim.x / 2; s>32; s >>= 1)
	{
		if (tid < s)
			if (sdata[tid] > sdata[tid + s]) sdata[tid] = sdata[tid + s];
		__syncthreads();
	}
	if (tid < 32)
	{
		if (sdata[tid] > sdata[tid + 32]) sdata[tid] = sdata[tid + 32];
		if (sdata[tid] > sdata[tid + 16]) sdata[tid] = sdata[tid + 16];
		if (sdata[tid] > sdata[tid + 8]) sdata[tid] = sdata[tid + 8];
		if (sdata[tid] > sdata[tid + 4]) sdata[tid] = sdata[tid + 4];
		if (sdata[tid] > sdata[tid + 2]) sdata[tid] = sdata[tid + 2];
		if (sdata[tid] > sdata[tid + 1]) sdata[tid] = sdata[tid + 1];
	}

	// write result for this block to global mem
	if (tid == 0) pMin_Dev[blockIdx.x] = sdata[0];
}

//This function calculates maximum in a given array.
//since syncthreads does not work inter-blocks, i will call this function twice
//first with 512*512 element and last with 512 elements
__global__ void 
Max8uGPU(Npp8u * pSrc_Dev, Npp8u * pMax_Dev)
{
	extern __shared__ Npp8u sdata[];
	//// each thread loads one element from global to shared mem
	unsigned int tid = threadIdx.x;
	unsigned int i = blockIdx.x * (blockDim.x * 2) + threadIdx.x;
	if (pSrc_Dev[i] < pSrc_Dev[i + blockDim.x])
	{
		sdata[tid] = pSrc_Dev[i + blockDim.x];
	}
	else
	{
		sdata[tid] = pSrc_Dev[i];
	}
	__syncthreads();

	for (unsigned int s = blockDim.x / 2; s>32; s >>= 1)
	{
		if (tid < s)
			if (sdata[tid] < sdata[tid + s]) sdata[tid] = sdata[tid + s];
		__syncthreads();
	}
	if (tid < 32)
	{
		if (sdata[tid] < sdata[tid + 32]) sdata[tid] = sdata[tid + 32];
		if (sdata[tid] < sdata[tid + 16]) sdata[tid] = sdata[tid + 16];
		if (sdata[tid] < sdata[tid + 8]) sdata[tid] = sdata[tid + 8];
		if (sdata[tid] < sdata[tid + 4]) sdata[tid] = sdata[tid + 4];
		if (sdata[tid] < sdata[tid + 2]) sdata[tid] = sdata[tid + 2];
		if (sdata[tid] < sdata[tid + 1]) sdata[tid] = sdata[tid + 1];
	}

	// write result for this block to global mem
	if (tid == 0) pMax_Dev[blockIdx.x] = sdata[0];
}

// Subtract Min from Source and set it to Destination
__global__ void 
SubMin8uGPU(Npp8u * pDst_Dev, Npp8u * pSrc_Dev, Npp8u nMin_Dev)
{
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	pDst_Dev[i] = pSrc_Dev[i] - nMin_Dev;
}

// multiply by nConstant and divide by 2 ^ nScaleFactor-1
__global__ void 
MulDiv8uGPU(Npp8u * pDst_Dev, Npp8u nConstant, int nScaleFactorMinus1)
{
	unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
	int divider = 1;
	for (int j = 0; j < nScaleFactorMinus1; j++) divider <<= 1;
	pDst_Dev[i] = static_cast<Npp8u>(llrintf(pDst_Dev[i] * nConstant / divider));
}

void StartCounter()
{
	LARGE_INTEGER li;
	if (!QueryPerformanceFrequency(&li))
		std::cout << "QueryPerformanceFrequency failed!\n";

	PCFreq = double(li.QuadPart) / 1000000.0;

	QueryPerformanceCounter(&li);
	CounterStart = li.QuadPart;
}
double GetCounter()
{
	LARGE_INTEGER li;
	QueryPerformanceCounter(&li);
	return double(li.QuadPart - CounterStart) / PCFreq;
}
