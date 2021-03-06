/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/device_ptr.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <iostream>
#include <vector>

#define TEXTURE_MAP 1
#define PERSPECTIVE_CORRECT 1
#define BILINEAR_INTERPOLATION 1
#define BACKFACE_CULL 1
#define NORMAL_INTERPOLATE 1

#define CEL_SHADE 4
#define SOBEL_GRID 8
#define USE_SHARED_SOBEL 1

namespace rasterizer {

  typedef unsigned short VertexIndex;
  typedef glm::vec3 VertexAttributePosition;
  typedef glm::vec3 VertexAttributeNormal;
  typedef glm::vec2 VertexAttributeTexcoord;
  typedef unsigned char TextureData;

  typedef unsigned char BufferByte;

  enum PrimitiveType{
    Point = 1,
    Line = 2,
    Triangle = 3
  };

  struct VertexOut {
    glm::vec4 pos;

    // TODO: add new attributes to your VertexOut
    // The attributes listed below might be useful, 
    // but always feel free to modify on your own

    glm::vec3 eyePos;	// eye space position used for shading
    glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
    // glm::vec3 col;
#if TEXTURE_MAP == 1
    glm::vec2 texcoord0;
    TextureData* dev_diffuseTex = NULL;
    int texWidth, texHeight, texComp;
#endif
    // ...
  };

  struct Primitive {
    PrimitiveType primitiveType = Triangle;	// C++ 11 init
    VertexOut v[3];
  };



  struct Fragment {
    glm::vec3 color;

    // TODO: add new attributes to your Fragment
    // The attributes listed below might be useful, 
    // but always feel free to modify on your own

    glm::vec3 eyePos;	// eye space position used for shading
    glm::vec3 eyeNor;

    float z;
    float sobelx;
    float sobely;

    TextureData * diffuseTex;
    int texWidth;
    int texHeight;
    int texComp;
    glm::vec2 texcoord0;
  };

  struct FragmentMutex {
    int mutex;
  };

  struct PrimitiveDevBufPointers {
    int primitiveMode;	//from tinygltfloader macro
    PrimitiveType primitiveType;
    int numPrimitives;
    int numIndices;
    int numVertices;

    // Vertex In, const after loaded
    VertexIndex* dev_indices;
    VertexAttributePosition* dev_position;
    VertexAttributeNormal* dev_normal;
    VertexAttributeTexcoord* dev_texcoord0;

    // Materials, add more attributes when needed
#if TEXTURE_MAP == 1
    TextureData* dev_diffuseTex;
    int texWidth;
    int texHeight;
    int texComp;
#endif
    // TextureData* dev_specularTex;
    // TextureData* dev_normalTex;
    // ...

    // Vertex Out, vertex used for rasterization, this is changing every frame
    VertexOut* dev_verticesOut;

    // TODO: add more attributes when needed
  };

}
using namespace rasterizer;

struct Light {
  glm::vec4 worldPos;
  glm::vec3 eyePos;
  float emittance;
  Light(glm::vec4 worldPos, float emittance) {
    this->worldPos = worldPos;
    this->emittance = emittance;
  }
};

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

#define AMBIENT_LIGHT 0.2f
std::vector<Light> lights = { Light(glm::vec4(0.0f, 10.0f, 4.0f, 1.0f), 1.0f) };

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;
static Light *dev_lights = NULL;
static FragmentMutex *dev_fragmentMutexes = NULL;

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * w);

  if (x < w && y < h) {
    glm::vec3 color;
    color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
    color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
    color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
    // Each thread writes one pixel location in the texture (textel)
    pbo[index].w = 0;
    pbo[index].x = color.x;
    pbo[index].y = color.y;
    pbo[index].z = color.z;
  }
}



/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
  width = w;
  height = h;
  cudaFree(dev_fragmentBuffer);
  cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
  cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
  cudaFree(dev_framebuffer);
  cudaMalloc(&dev_framebuffer, width * height * sizeof(glm::vec3));
  cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));

  cudaFree(dev_lights);
  cudaMalloc(&dev_lights, lights.size() * sizeof(Light));

  cudaFree(dev_fragmentMutexes);
  cudaMalloc(&dev_fragmentMutexes, width * height * sizeof(FragmentMutex));

  checkCUDAError("rasterizeInit");
}

__global__
void initMutexes(int w, int h, FragmentMutex * mutexes, Fragment * fragments) {
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;

  if (x < w && y < h)
  {
    int index = x + (y * w);
    mutexes[index].mutex = 0;
    fragments[index].z = FLT_MAX;
  }
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {

  // Attribute (vec3 position)
  // component (3 * float)
  // byte (4 * byte)

  // id of component
  int i = (blockIdx.x * blockDim.x) + threadIdx.x;

  if (i < N) {
    int count = i / n;
    int offset = i - count * n;	// which component of the attribute

    for (int j = 0; j < componentTypeByteSize; j++) {

      dev_dst[count * componentTypeByteSize * n
        + offset * componentTypeByteSize
        + j]

        =

        dev_src[byteOffset
        + count * (byteStride == 0 ? componentTypeByteSize * n : byteStride)
        + offset * componentTypeByteSize
        + j];
    }
  }


}

__global__
void _nodeMatrixTransform(
int numVertices,
VertexAttributePosition* position,
VertexAttributeNormal* normal,
glm::mat4 MV, glm::mat3 MV_normal) {

  // vertex id
  int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (vid < numVertices) {
    position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
    normal[vid] = glm::normalize(MV_normal * normal[vid]);
  }
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {

  glm::mat4 curMatrix(1.0);

  const std::vector<double> &m = n.matrix;
  if (m.size() > 0) {
    // matrix, copy it

    for (int i = 0; i < 4; i++) {
      for (int j = 0; j < 4; j++) {
        curMatrix[i][j] = (float)m.at(4 * i + j);
      }
    }
  }
  else {
    // no matrix, use rotation, scale, translation

    if (n.translation.size() > 0) {
      curMatrix[3][0] = n.translation[0];
      curMatrix[3][1] = n.translation[1];
      curMatrix[3][2] = n.translation[2];
    }

    if (n.rotation.size() > 0) {
      glm::mat4 R;
      glm::quat q;
      q[0] = n.rotation[0];
      q[1] = n.rotation[1];
      q[2] = n.rotation[2];

      R = glm::mat4_cast(q);
      curMatrix = curMatrix * R;
    }

    if (n.scale.size() > 0) {
      curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
    }
  }

  return curMatrix;
}

void traverseNode(
  std::map<std::string, glm::mat4> & n2m,
  const tinygltf::Scene & scene,
  const std::string & nodeString,
  const glm::mat4 & parentMatrix
  )
{
  const tinygltf::Node & n = scene.nodes.at(nodeString);
  glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
  n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

  auto it = n.children.begin();
  auto itEnd = n.children.end();

  for (; it != itEnd; ++it) {
    traverseNode(n2m, scene, *it, M);
  }
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

  totalNumPrimitives = 0;

  std::map<std::string, BufferByte*> bufferViewDevPointers;

  // 1. copy all `bufferViews` to device memory
  {
    std::map<std::string, tinygltf::BufferView>::const_iterator it(
      scene.bufferViews.begin());
    std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
      scene.bufferViews.end());

    for (; it != itEnd; it++) {
      const std::string key = it->first;
      const tinygltf::BufferView &bufferView = it->second;
      if (bufferView.target == 0) {
        continue; // Unsupported bufferView.
      }

      const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

      BufferByte* dev_bufferView;
      cudaMalloc(&dev_bufferView, bufferView.byteLength);
      cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

      checkCUDAError("Set BufferView Device Mem");

      bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

    }
  }



  // 2. for each mesh: 
  //		for each primitive: 
  //			build device buffer of indices, materail, and each attributes
  //			and store these pointers in a map
  {

    std::map<std::string, glm::mat4> nodeString2Matrix;
    auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

    {
      auto it = rootNodeNamesList.begin();
      auto itEnd = rootNodeNamesList.end();
      for (; it != itEnd; ++it) {
        traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
      }
    }


    // parse through node to access mesh

    auto itNode = nodeString2Matrix.begin();
    auto itEndNode = nodeString2Matrix.end();
    for (; itNode != itEndNode; ++itNode) {

      const tinygltf::Node & N = scene.nodes.at(itNode->first);
      const glm::mat4 & matrix = itNode->second;
      const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

      auto itMeshName = N.meshes.begin();
      auto itEndMeshName = N.meshes.end();

      for (; itMeshName != itEndMeshName; ++itMeshName) {

        const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

        auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
        std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

        // for each primitive
        for (size_t i = 0; i < mesh.primitives.size(); i++) {
          const tinygltf::Primitive &primitive = mesh.primitives[i];

          if (primitive.indices.empty())
            return;

          VertexIndex* dev_indices;
          VertexAttributePosition* dev_position;
          VertexAttributeNormal* dev_normal;
          VertexAttributeTexcoord* dev_texcoord0;


          // ----------Indices-------------

          const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
          const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
          BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

          // assume type is SCALAR for indices
          int n = 1;
          int numIndices = indexAccessor.count;
          int componentTypeByteSize = sizeof(VertexIndex);
          int byteLength = numIndices * n * componentTypeByteSize;

          dim3 numThreadsPerBlock(128);
          dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
          cudaMalloc(&dev_indices, byteLength);
          _deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
            numIndices,
            (BufferByte*)dev_indices,
            dev_bufferView,
            n,
            indexAccessor.byteStride,
            indexAccessor.byteOffset,
            componentTypeByteSize);


          checkCUDAError("Set Index Buffer");


          // ---------Primitive Info-------

          // Warning: LINE_STRIP is not supported in tinygltfloader
          int numPrimitives;
          PrimitiveType primitiveType;
          switch (primitive.mode) {
          case TINYGLTF_MODE_TRIANGLES:
            primitiveType = PrimitiveType::Triangle;
            numPrimitives = numIndices / 3;
            break;
          case TINYGLTF_MODE_TRIANGLE_STRIP:
            primitiveType = PrimitiveType::Triangle;
            numPrimitives = numIndices - 2;
            break;
          case TINYGLTF_MODE_TRIANGLE_FAN:
            primitiveType = PrimitiveType::Triangle;
            numPrimitives = numIndices - 2;
            break;
          case TINYGLTF_MODE_LINE:
            primitiveType = PrimitiveType::Line;
            numPrimitives = numIndices / 2;
            break;
          case TINYGLTF_MODE_LINE_LOOP:
            primitiveType = PrimitiveType::Line;
            numPrimitives = numIndices + 1;
            break;
          case TINYGLTF_MODE_POINTS:
            primitiveType = PrimitiveType::Point;
            numPrimitives = numIndices;
            break;
          default:
            // output error
            break;
          };


          // ----------Attributes-------------

          auto it(primitive.attributes.begin());
          auto itEnd(primitive.attributes.end());

          int numVertices = 0;
          // for each attribute
          for (; it != itEnd; it++) {
            const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
            const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

            int n = 1;
            if (accessor.type == TINYGLTF_TYPE_SCALAR) {
              n = 1;
            }
            else if (accessor.type == TINYGLTF_TYPE_VEC2) {
              n = 2;
            }
            else if (accessor.type == TINYGLTF_TYPE_VEC3) {
              n = 3;
            }
            else if (accessor.type == TINYGLTF_TYPE_VEC4) {
              n = 4;
            }

            BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
            BufferByte ** dev_attribute = NULL;

            numVertices = accessor.count;
            int componentTypeByteSize;

            // Note: since the type of our attribute array (dev_position) is static (float32)
            // We assume the glTF model attribute type are 5126(FLOAT) here

            if (it->first.compare("POSITION") == 0) {
              componentTypeByteSize = sizeof(VertexAttributePosition) / n;
              dev_attribute = (BufferByte**)&dev_position;
            }
            else if (it->first.compare("NORMAL") == 0) {
              componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
              dev_attribute = (BufferByte**)&dev_normal;
            }
            else if (it->first.compare("TEXCOORD_0") == 0) {
              componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
              dev_attribute = (BufferByte**)&dev_texcoord0;
            }

            std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

            dim3 numThreadsPerBlock(128);
            dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
            int byteLength = numVertices * n * componentTypeByteSize;
            cudaMalloc(dev_attribute, byteLength);

            _deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
              n * numVertices,
              *dev_attribute,
              dev_bufferView,
              n,
              accessor.byteStride,
              accessor.byteOffset,
              componentTypeByteSize);

            std::string msg = "Set Attribute Buffer: " + it->first;
            checkCUDAError(msg.c_str());
          }

          // malloc for VertexOut
          VertexOut* dev_vertexOut;
          cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
          checkCUDAError("Malloc VertexOut Buffer");

          // ----------Materials-------------

          // You can only worry about this part once you started to 
          // implement textures for your rasterizer
          TextureData* dev_diffuseTex = NULL;
#if TEXTURE_MAP == 1
          int texWidth = 0;
          int texHeight = 0;
          int texComp = 0;
#endif
          if (!primitive.material.empty()) {
            const tinygltf::Material &mat = scene.materials.at(primitive.material);
            printf("material.name = %s\n", mat.name.c_str());

            if (mat.values.find("diffuse") != mat.values.end()) {
              std::string diffuseTexName = mat.values.at("diffuse").string_value;
              if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
                const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
                if (scene.images.find(tex.source) != scene.images.end()) {
                  const tinygltf::Image &image = scene.images.at(tex.source);

                  size_t s = image.image.size() * sizeof(TextureData);
                  cudaMalloc(&dev_diffuseTex, s);
                  cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);

#if TEXTURE_MAP == 1
                  texWidth = image.width;
                  texHeight = image.height;
                  texComp = image.component;
#endif

                  checkCUDAError("Set Texture Image data");
                }
              }
            }

            // TODO: write your code for other materails
            // You may have to take a look at tinygltfloader
            // You can also use the above code loading diffuse material as a start point 
          }


          // ---------Node hierarchy transform--------
          cudaDeviceSynchronize();

          dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
          _nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
            numVertices,
            dev_position,
            dev_normal,
            matrix,
            matrixNormal);

          checkCUDAError("Node hierarchy transformation");

          // at the end of the for loop of primitive
          // push dev pointers to map
          primitiveVector.push_back(PrimitiveDevBufPointers{
            primitive.mode,
            primitiveType,
            numPrimitives,
            numIndices,
            numVertices,

            dev_indices,
            dev_position,
            dev_normal,
            dev_texcoord0,
#if TEXTURE_MAP == 1
            dev_diffuseTex,
            texWidth,
            texHeight,
            texComp,
#endif

            dev_vertexOut	//VertexOut
          });

          totalNumPrimitives += numPrimitives;

        } // for each primitive

      } // for each mesh

    } // for each node

  }


  // 3. Malloc for dev_primitives
  {
    cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
  }


  // Finally, cudaFree raw dev_bufferViews
  {

    std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
    std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());

    //bufferViewDevPointers

    for (; it != itEnd; it++) {
      cudaFree(it->second);
    }
    checkCUDAError("Free BufferView Device Mem");
  }

}



__global__
void _vertexTransformAndAssembly(
int numVertices,
PrimitiveDevBufPointers primitive,
glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal,
int width, int height) {

  // vertex id
  int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (vid < numVertices) {
    VertexOut & vout = primitive.dev_verticesOut[vid];
    VertexAttributePosition & vpos = primitive.dev_position[vid];
    // Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
    // Then divide the pos by its w element to transform into NDC space
    // Finally transform x and y to viewport space
    vout.pos = MVP * glm::vec4(vpos, 1.0f);
    if (fabs(vout.pos.w) > EPSILON) vout.pos /= vout.pos.w;
    vout.pos.x = 0.5f * (float)width * (vout.pos.x + 1.0f);
    vout.pos.y = 0.5f * (float)height * (vout.pos.y + 1.0f);

    // Assemble all attribute arraies into the primitive array
    VertexAttributeNormal & vnorm = primitive.dev_normal[vid];
    glm::vec4 eyePos = MV * glm::vec4(vpos, 1.0f);
    if (fabs(eyePos.w) > EPSILON) vout.eyePos = glm::vec3(eyePos / eyePos.w);
    vout.eyeNor = glm::normalize(MV_normal * vnorm);

#if TEXTURE_MAP == 1
    //Textures
    if (primitive.dev_diffuseTex != NULL) {
      vout.texcoord0 = primitive.dev_texcoord0[vid];
    }
    vout.dev_diffuseTex = primitive.dev_diffuseTex;
    vout.texWidth = primitive.texWidth;
    vout.texHeight = primitive.texHeight;
    vout.texComp = primitive.texComp;
#endif
  }
}



static int curPrimitiveBeginId = 0;

__global__
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

  // index id
  int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

  if (iid < numIndices) {
    // This is primitive assembly for triangles
    int pid;	// id for cur primitives vector
    if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) {
      pid = iid / (int)primitive.primitiveType;
      dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
        = primitive.dev_verticesOut[primitive.dev_indices[iid]];
    }


    // TODO: other primitive types (point, line)
  }

}

__device__ __host__
int clamp_int(int mn, int x, int mx) {
  if (x > mx) return mx;
  if (x < mn) return mn;
  return x;
}

__device__ __host__
glm::vec3 getPixel(int x, int y, int width, int height, int components, TextureData * tex) {
  if (x >= width || y >= height || x < 0 || y < 0) {
    return glm::vec3(0, 0, 0);
  }
  int texIdx = y * width + x;
  return (1.0f / 255.0f) * glm::vec3(tex[components * texIdx], tex[components * texIdx + 1], tex[components * texIdx + 2]);
}

__global__
void kernRasterize(int numPrimitives, Primitive* dev_primitives,
int width, int height, Fragment* fragmentBuffer, FragmentMutex* mutexes) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < numPrimitives) {
    Primitive & p = dev_primitives[index];
    VertexOut & firstVertex = p.v[0];
    glm::vec3 triangle[3] = { glm::vec3(p.v[0].pos), glm::vec3(p.v[1].pos), glm::vec3(p.v[2].pos) };
    AABB boundingBox = getAABBForTriangle(triangle);
    int minxpix = clamp_int(0, boundingBox.min.x, width - 1);
    int minypix = clamp_int(0, boundingBox.min.y, height - 1);
    int maxxpix = clamp_int(0, boundingBox.max.x, width - 1);
    int maxypix = clamp_int(0, boundingBox.max.y, height - 1);
    for (int y = minypix; y <= maxypix; y++) {
      for (int x = minxpix; x <= maxxpix; x++) {
        int fragIdx = (height - 1 - y) * width + (width - 1 - x);
        Fragment & fragment = fragmentBuffer[fragIdx];

        glm::vec3 baryCoords = calculateBarycentricCoordinate(triangle, glm::vec2(x, y));
        if (isBarycentricCoordInBounds(baryCoords)) {
          float pos = glm::dot(baryCoords, glm::vec3(p.v[0].pos.z, p.v[1].pos.z, p.v[2].pos.z));
          bool isSet;
          do {
            isSet = atomicCAS(&mutexes[fragIdx].mutex, 0, 1) == 0;
            if (isSet) {
              if (pos < fragment.z) {
                fragment.z = pos;
#if TEXTURE_MAP == 1
                if (p.v[0].dev_diffuseTex == NULL) {
                  fragment.color = glm::vec3(1.0f, 1.0f, 1.0f); // white
                  fragment.diffuseTex = NULL;
                }
                else {
#if PERSPECTIVE_CORRECT == 1
                  glm::vec3 perspectiveBaryCoords = glm::vec3(baryCoords.x / p.v[0].eyePos.z, baryCoords.y / p.v[1].eyePos.z, baryCoords.z / p.v[2].eyePos.z);
                  float scaleFactor = (1.0f / (perspectiveBaryCoords.x + perspectiveBaryCoords.y + perspectiveBaryCoords.z));
                  fragment.texcoord0 = glm::mat3x2(p.v[0].texcoord0, p.v[1].texcoord0, p.v[2].texcoord0)
                    * perspectiveBaryCoords * scaleFactor;
#else
                  fragment.texcoord0 = glm::mat3x2(p.v[0].texcoord0, p.v[1].texcoord0, p.v[2].texcoord0) * baryCoords;
#endif
                  fragment.texWidth = firstVertex.texWidth;
                  fragment.texHeight = firstVertex.texHeight;
                  fragment.texComp = firstVertex.texComp;
                  fragment.diffuseTex = firstVertex.dev_diffuseTex;
                }
#else
                fragment.color = glm::vec3(1.0f, 1.0f, 1.0f); // white
#endif
                fragment.eyePos = glm::mat3(p.v[0].eyePos, p.v[1].eyePos, p.v[2].eyePos) * baryCoords;
#if NORMAL_INTERPOLATE == 1
                fragment.eyeNor = glm::mat3(p.v[0].eyeNor, p.v[1].eyeNor, p.v[2].eyeNor) * baryCoords;
#else
                fragment.eyeNor = glm::normalize(glm::cross(
                  glm::vec3(p.v[1].eyeNor - p.v[0].eyeNor),
                  glm::vec3(p.v[2].eyeNor - p.v[0].eyeNor)
                ));
#endif
                }
              }
            if (isSet) {
              mutexes[fragIdx].mutex = 0;
            }
            } while (pos < fragment.z && !isSet);
          }
        }
      }
    }
  }

__global__
void kernTextureShader(int width, int height, Fragment* fragmentBuffer) {
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * width);

  if (x < width && y < height) {
    Fragment & fragment = fragmentBuffer[index];
    if (fragment.diffuseTex != NULL) {
      float texx = 0.5f + fragment.texcoord0.x * (fragment.texWidth - 1);
      float texy = 0.5f + fragment.texcoord0.y * (fragment.texHeight - 1);
#if BILINEAR_INTERPOLATION == 1
      float x1 = glm::floor(texx);
      float y1 = glm::floor(texy);
      glm::vec3 c11 = getPixel(x1, y1, fragment.texWidth, fragment.texHeight, fragment.texComp, fragment.diffuseTex);
      glm::vec3 c12 = getPixel(x1, y1 + 1, fragment.texWidth, fragment.texHeight, fragment.texComp, fragment.diffuseTex);
      glm::vec3 c21 = getPixel(x1 + 1, y1, fragment.texWidth, fragment.texHeight, fragment.texComp, fragment.diffuseTex);
      glm::vec3 c22 = getPixel(x1 + 1, y1 + 1, fragment.texWidth, fragment.texHeight, fragment.texComp, fragment.diffuseTex);
      glm::vec3 r1 = (texx - x1) * c21 + (1.0f + x1 - texx) * c11;
      glm::vec3 r2 = (texx - x1) * c22 + (1.0f + x1 - texx) * c12;
      fragment.color = (texy - y1) * r2 + (1.0f + y1 - texy) * r1;
#else
      fragment.color = getPixel(texx, texy, fragment.texWidth, fragment.texHeight, fragment.texComp, fragment.diffuseTex);
#endif
    }
  }
}

struct IsBackfacing {
  __host__ __device__ bool operator () (const Primitive & p) {
    glm::vec3 normal = glm::normalize(glm::cross(
      glm::vec3(p.v[1].pos - p.v[0].pos),
      glm::vec3(p.v[2].pos - p.v[0].pos)));
    return normal.z < -0;
  }
};

__global__
void calculateSobel(int w, int h, Fragment * fragmentBuffer) {
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * w);
  float sobelKernel[3][3] = { { -1, 0, 1 }, { -2, 0, 2 }, { -1, 0, 1 } };
  if (x < w && y < h) {
    Fragment & fragment = fragmentBuffer[index];
    for (int i = -1; i <= 1; i++) {
      for (int j = -1; j <= 1; j++) {
        if (x + i < w && x + i >= 0 && y + j < h && y + j >= 0) {
          int sobelIdx = x + i + ((y + j) * w);
          float dist = (fragmentBuffer[sobelIdx].z > 1e12) ? 1e12 : glm::length(fragmentBuffer[sobelIdx].eyePos);
          fragment.sobelx += sobelKernel[i + 1][j + 1] * dist;
          fragment.sobely += sobelKernel[j + 1][i + 1] * dist;
        }
      }
    }
  }
}

__global__
void calculateSobelWithShared(int w, int h, Fragment * fragmentBuffer) {
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * w);
  __shared__ float tile[SOBEL_GRID][SOBEL_GRID];
  __shared__ float sobelx[SOBEL_GRID][SOBEL_GRID];
  __shared__ float sobely[SOBEL_GRID][SOBEL_GRID];
  float sobelKernel[3][3] = { { 3, 0, -3 }, { 10, 0, -10 }, { 3, 0, -3 } };
  if (x < w && y < h) {
    int bx = threadIdx.x;
    int by = threadIdx.y;
    Fragment & fragment = fragmentBuffer[index];
    tile[bx][by] = (fragment.z > 1e12) ? 1e12 : glm::length(fragment.eyePos);
    sobelx[bx][by] = 0;
    sobely[bx][by] = 0;
    __syncthreads();

    for (int i = -1; i <= 1; i++) {
      for (int j = -1; j <= 1; j++) {
        if (bx + i < SOBEL_GRID && bx + i >= 0 && by + j < SOBEL_GRID && by + j >= 0) {
          sobelx[bx][by] += sobelKernel[i + 1][j + 1] * tile[bx + i][by + j];
          sobely[bx][by] += sobelKernel[j + 1][i + 1] * tile[bx + i][by + j];
        }
        else {
          if (x + i < w && x + i >= 0 && y + j < h && y + j >= 0) {
            int sobelIdx = x + i + ((y + j) * w);
            float dist = (fragmentBuffer[sobelIdx].z > 1e12) ? 1e12 : glm::length(fragmentBuffer[sobelIdx].eyePos);
            sobelx[bx][by] += sobelKernel[i + 1][j + 1] * dist;
            sobely[bx][by] += sobelKernel[j + 1][i + 1] * dist;
          }
        }
      }
    }
    fragment.sobelx = sobelx[bx][by];
    fragment.sobely = sobely[bx][by];
  }
}

/**
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer, int numLights, Light *lights) {
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * w);

  if (x < w && y < h) {
    Fragment & fragment = fragmentBuffer[index];
    if (fragment.z < 1e12) {
      float totalLight = AMBIENT_LIGHT;

      // Lambert shading
      for (int i = 0; i < numLights; i++) {
        Light & light = lights[i];
        totalLight += light.emittance * glm::max(0.0f,
          glm::dot(fragment.eyeNor, glm::normalize(light.eyePos - fragment.eyePos)));
      }
      framebuffer[index] = totalLight * fragment.color;
#if CEL_SHADE > 0
      framebuffer[index] = glm::ceil(framebuffer[index] * (float)CEL_SHADE) / (float)CEL_SHADE;
      float sobel = glm::sqrt(fragment.sobelx * fragment.sobelx + fragment.sobely * fragment.sobely);
      if (sobel > 15.0f) framebuffer[index] = glm::vec3(0.0f, 0.0f, 0.0f);
#endif
    }
    else {
      framebuffer[index] = glm::vec3(0.5f, 0.8f, 1.0f);
    }
  }
}

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
  int sideLength2d = 8;
  dim3 blockSize2d(sideLength2d, sideLength2d);
  dim3 blockCount2d((width - 1) / blockSize2d.x + 1,
    (height - 1) / blockSize2d.y + 1);

  // Execute your rasterization pipeline here
  // (See README for rasterization pipeline outline.)

  // Vertex Process & primitive assembly
  {
    curPrimitiveBeginId = 0;
    dim3 numThreadsPerBlock(128);

    auto it = mesh2PrimitivesMap.begin();
    auto itEnd = mesh2PrimitivesMap.end();

    for (; it != itEnd; ++it) {
      auto p = (it->second).begin();	// each primitive
      auto pEnd = (it->second).end();
      for (; p != pEnd; ++p) {
        dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
        dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

        _vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height);
        checkCUDAError("Vertex Processing");
        cudaDeviceSynchronize();
        _primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
          (p->numIndices,
          curPrimitiveBeginId,
          dev_primitives,
          *p);
        checkCUDAError("Primitive Assembly");

        curPrimitiveBeginId += p->numPrimitives;
      }
    }

    checkCUDAError("Vertex Processing and Primitive Assembly");
  }

  cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
  initMutexes << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentMutexes, dev_fragmentBuffer);
  checkCUDAError("init mutexes");

  int numPrimitives = totalNumPrimitives;

  // Backface culling
#if BACKFACE_CULL == 1
  thrust::device_ptr<Primitive> dev_thrust_primitives(dev_primitives);
  thrust::device_ptr<Primitive> dev_thrust_primitivesEnd =
    thrust::remove_if(dev_thrust_primitives, dev_thrust_primitives + numPrimitives, IsBackfacing());
  numPrimitives = dev_thrust_primitivesEnd - dev_thrust_primitives;
  printf("%d triangles\n", numPrimitives);
  checkCUDAError("backface culling");
#endif


  // Rasterization
  dim3 numThreadsPerBlock(64);
  dim3 numBlocksForPrimitives((numPrimitives + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
  kernRasterize << < numBlocksForPrimitives, numThreadsPerBlock >> >(
    numPrimitives, dev_primitives,
    width, height, dev_fragmentBuffer, dev_fragmentMutexes);
  checkCUDAError("rasterizer");

  // Filling texture colors
#if TEXTURE_MAP == 1
  kernTextureShader << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer);
  checkCUDAError("textureShader");
#endif

  // Offline light transformation, since there aren't many lights
  for (Light & light : lights) {
    glm::vec4 eyePos = MV * light.worldPos;
    light.eyePos = glm::vec3(eyePos / eyePos.w);
  }
  cudaMemcpy(dev_lights, lights.data(), lights.size() * sizeof(Light), cudaMemcpyHostToDevice);

#if CEL_SHADE > 0
  dim3 sobelBlockSize2d(SOBEL_GRID, SOBEL_GRID);
  dim3 sobelBlockCount2d((width - 1) / sobelBlockSize2d.x + 1,
    (height - 1) / sobelBlockSize2d.y + 1);
#if USE_SHARED_SOBEL == 1
  calculateSobelWithShared<< <sobelBlockCount2d, sobelBlockSize2d >> >(width, height, dev_fragmentBuffer);
#else
  calculateSobel<< <sobelBlockCount2d, sobelBlockSize2d >> >(width, height, dev_fragmentBuffer);
#endif
  checkCUDAError("Sobel");
#endif

  // Copy depthbuffer colors into framebuffer
  render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer,
    lights.size(), dev_lights);
  checkCUDAError("fragment shader");


  // Copy framebuffer into OpenGL buffer for OpenGL previewing
  sendImageToPBO << <blockCount2d, blockSize2d >> >(pbo, width, height, dev_framebuffer);
  checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

  // deconstruct primitives attribute/indices device buffer

  auto it(mesh2PrimitivesMap.begin());
  auto itEnd(mesh2PrimitivesMap.end());
  for (; it != itEnd; ++it) {
    for (auto p = it->second.begin(); p != it->second.end(); ++p) {
      cudaFree(p->dev_indices);
      cudaFree(p->dev_position);
      cudaFree(p->dev_normal);
      cudaFree(p->dev_texcoord0);
#if TEXTURE_MAP == 1
      cudaFree(p->dev_diffuseTex);
#endif

      cudaFree(p->dev_verticesOut);
    }
  }

  ////////////

  cudaFree(dev_primitives);
  dev_primitives = NULL;

  cudaFree(dev_fragmentBuffer);
  dev_fragmentBuffer = NULL;

  cudaFree(dev_framebuffer);
  dev_framebuffer = NULL;

  cudaFree(dev_lights);
  dev_lights = NULL;

  checkCUDAError("rasterize Free");
}
