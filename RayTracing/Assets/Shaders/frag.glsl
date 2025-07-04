#version 430 core

out vec4 FragColor;

const int DIFFUSE = 0;
const int SPECULAR = 1;
const int LIGHT = 2;
const int CHECKER = 3;
const int GLASS = 4;
const int TEXTURE = 5;

const int MAX_DEPTH = 32;

struct Material
{
    vec4 color;
    vec4 specularColor;
    vec4 emissionColor;

    int textureIndex;
    float emissionStrength;
    float smoothness; 
    float specularProbability;

    float checkerScale;
    float refractiveIndex;
    int materialType; // 76 bytes
    float pad0; // padded, 80 bytes
};

struct Sphere
{
	Material material;
	vec3 center;
	float radius;
};

struct Triangle
{
	Material material;
	vec3 a;
	vec3 b;
	vec3 c;
	vec2 aTex;
	vec2 bTex;
	vec2 cTex;
	float pad[2];
};

struct BoundingBox
{
    vec3 bmin;
    float pad0;
    vec3 bmax;
    float pad1;
};

struct Node
{
    BoundingBox bounds;
    int triangleIndex;
    int triangleCount;
    int childIndex;
    int pad0;
};

layout(binding = 0, std430) buffer TrianglesBlock
{
	Triangle triangles[];
};

layout(binding = 1, std430) buffer NodesBlock
{
	Node allNodes[];
};

struct Ray
{
	vec3 origin;
	vec3 direction;
	bool insideGlass;
};

struct HitInfo
{
	Material material;
	bool didHit;
	vec3 hitPoint;
	vec3 normal;
	float dst;
	int triangleIndex;
};

const int MAX_TEXTURES = 5;
uniform sampler2D textures[MAX_TEXTURES];

layout(binding = 2, std140) uniform GlobalUniformsBlock {
    int pad;
    int numTextures;
    uint width;
    uint height;

    int numSpheres;
    int numTriangles;
    bool basicShading;
    bool basicShadingShadow;

    vec4 basicShadingLightPosition;

    bool environmentalLight;
    int maxBounceCount;
    int numRaysPerPixel;
    uint frameIndex;

    vec4 cameraPos;
    vec4 viewportRight;
    vec4 viewportUp;
    vec4 viewportFront;

    vec4 pixelRight;
    vec4 pixelUp;
    vec4 defocusDiskRight;
    vec4 defocusDiskUp;
};

in vec3 fragPos;

float random(inout uint state)
{
	state = state * 747796405u + 2891336453u;
	uint result = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	result = (result >> 22u) ^ result;
	return result /  4294967295.0; // 2^32 - 1
}

float random(float left, float right, inout uint state)
{
	return left + (right - left) * random(state);
}

vec2 randomDirection2D(inout uint rngState)
{
	float angle = random(rngState);
	return vec2(cos(angle), sin(angle));
}

float randomNormalDist(inout uint rngState)
{
	float theta = 2 * 3.1415926 * random(rngState);
	float rho = sqrt(-2 * log(random(rngState)));
	return rho + cos(theta);
}

vec3 randomDirection(inout uint rngState)
{
	for (int i = 0; i < 100; i++)
	{
		float x = random(rngState) * 2.0f - 1.0f;
		float y = random(rngState) * 2.0f - 1.0f;
		float z = random(rngState) * 2.0f - 1.0f;
		if (length(vec3(x, y, z)) < 1.0f)
			return normalize(vec3(x, y, z));
	}
	return vec3(0.0f);
}

vec3 randomDirectionAlt(inout uint rngState)
{
	float x = randomNormalDist(rngState);
	float y = randomNormalDist(rngState);
	float z = randomNormalDist(rngState);
	return normalize(vec3(x, y, z));
}

vec3 randomDirectionHemisphere(vec3 normal, inout uint rngState)
{
	vec3 dir = randomDirection(rngState);
	return dir * sign(dot(dir, normal));
}

vec3 refract_(vec3 I, vec3 N, float eta, inout bool isRefracted)
	{
	float k = 1.0 - eta * eta * (1.0 - dot(N, I) * dot(N, I));
	if (k < 0.0)
	{
		isRefracted = false;
		return reflect(I, N);
	}
	else
	{
		isRefracted = true;
		return eta * I - (eta * dot(N, I) + sqrt(k)) * N;
	}
}

vec3 getEnvironmentalLight(Ray ray)
{
	return (ray.direction.y > 0) ?
			mix(mix(vec3(1.0f, 1.0f, 1.0f), vec3(0.0f, 0.0f, 1.0f), ray.direction.y * 0.5f + 0.5f),
				mix(vec3(0.0f, 0.0f, 1.0f), vec3(1.0f, 0.4f, 0.0f), ray.direction.x * 0.5f + 0.5f), 0.9f) :
			mix(vec3(1.0f, 1.0f, 1.0f), vec3(0.1f, 0.05f, 0.1f), -max(ray.direction.y, -1.0f) * 2);
}

HitInfo raySphereIntersect(Ray ray, Sphere sphere)
{
	vec3 rayOriginTrans = ray.origin - sphere.center.xyz;
	float a = dot(ray.direction, ray.direction);
	float b = 2 * dot(rayOriginTrans, ray.direction);
	float c = dot(rayOriginTrans, rayOriginTrans) - sphere.radius * sphere.radius;
	float delta = b * b - 4 * a * c;

	HitInfo hitInfo;
	hitInfo.didHit = false;

	if (delta >= 0)
	{
		float dst = (-b - sqrt(delta)) / (2 * a);
		if (dst >= 0.0f)
		{
			hitInfo.didHit = true;
			hitInfo.hitPoint = ray.origin + ray.direction * dst;
			hitInfo.normal = normalize(hitInfo.hitPoint - sphere.center);
			hitInfo.dst = dst;
			hitInfo.material = sphere.material;
		}
	}

	return hitInfo;
}

HitInfo rayTriangleIntersect(Ray ray, Triangle tri, int triIndex)
{
	HitInfo hitInfo;
	hitInfo.didHit = false;

	vec3 e0 = tri.b.xyz - tri.a.xyz;
	vec3 e1 = tri.c.xyz - tri.a.xyz;
	vec3 cross01 = cross(e0, e1);
	float det = -dot(ray.direction, cross01);

	if (det < 1e-10f && det > -1e-10f || det < 0)
		return hitInfo;
	
	float invDet = 1.0f / det;
	vec3 ao = ray.origin - tri.a.xyz;
	float dst = dot(ao, cross01) * invDet;

	if (dst <= 0)
		return hitInfo;

	vec3 dirCrossAO = cross(ray.direction, ao);
	float u = -dot(e1, dirCrossAO) * invDet;
	float v = dot(e0, dirCrossAO) * invDet;

	if (u < 0 || v < 0 || 1 - u - v < 0)
		return hitInfo;

	hitInfo.didHit = true;
	hitInfo.hitPoint = ray.origin + ray.direction * dst;
	hitInfo.normal = normalize(cross01);
	hitInfo.dst = dst;
	hitInfo.material = tri.material;
	hitInfo.triangleIndex = triIndex;
	
	return hitInfo;
}

vec3 getTriangleTextureColor(Ray ray, Triangle tri, int textureIndex)
{
	vec3 e0 = tri.b.xyz - tri.a.xyz;
	vec3 e1 = tri.c.xyz - tri.a.xyz;
	vec3 cross01 = cross(e0, e1);
	float det = -dot(ray.direction, cross01);
	
	float invDet = 1.0f / det;
	vec3 ao = ray.origin - tri.a.xyz;
	float dst = dot(ao, cross01) * invDet;


	vec3 dirCrossAO = cross(ray.direction, ao);
	float u = -dot(e1, dirCrossAO) * invDet;
	float v = dot(e0, dirCrossAO) * invDet;
	float w = 1.0f - u - v;

	vec2 uv = tri.aTex * u + tri.bTex * v + tri.cTex * w;

	// if (textureIndex < 0 || textureIndex >= numTextures)
	// 	return vec3(0.0f, 0.0f, 0.0f);

	return texture(textures[textureIndex], uv).rgb;
}

bool isCloseToZero(float val)
{
	return (val < 1e-6f) && (val > -1e-6f);
}

void swap(inout float a, inout float b)
{
	float temp = a;
	a = b;
	b = temp;
}

float rayBoundsIntersect(Ray ray, BoundingBox bounds)
{
	float tMin = -1e32f;
	float tMax = 1e32f;

	vec3 origin = ray.origin;
	vec3 direction = ray.direction;
	vec3 bmin = bounds.bmin;
	vec3 bmax = bounds.bmax;

	for (int i = 0; i < 3; i++)
	{
		if (!isCloseToZero(direction[i]))
		{
			float t0 = (bmin[i] - origin[i]) / direction[i];
			float t1 = (bmax[i] - origin[i]) / direction[i];

			if (t0 > t1) swap(t0, t1);
			if (tMin < t0) tMin = t0;
			if (tMax > t1) tMax = t1;

			if (tMin >= tMax || tMax < 0) return 1e38f;
		}
	}

	return tMin;
}

HitInfo calculateRayCollisionBVH(Ray ray)
{
	int stack[MAX_DEPTH];
	int stackIndex = 0;
	stack[stackIndex++] = 0;

	HitInfo result;
	result.dst = 1e38f;
	result.didHit = false;

	while(stackIndex > 0)
	{
		stackIndex -= 1;

		int nodeIndex = stack[stackIndex];
		Node node = allNodes[nodeIndex];

		if (node.childIndex == -1)
		{				
			for (int i = node.triangleIndex; i < node.triangleIndex + node.triangleCount; i++)
			{
				HitInfo hitInfo = rayTriangleIntersect(ray, triangles[i], i);
				if (hitInfo.didHit)
					if (hitInfo.dst < result.dst)
						result = hitInfo;
			}
			// if (result.didHit) 
			// 	return result;
		}
		else
		{
			int childIndexA = node.childIndex;
			int childIndexB = node.childIndex + 1; 
			Node childA = allNodes[childIndexA];
			Node childB = allNodes[childIndexB];
			
			float dstA = rayBoundsIntersect(ray, childA.bounds);
			float dstB = rayBoundsIntersect(ray, childB.bounds);

			bool isNearestA = dstA < dstB;
			float dstNear = isNearestA ? dstA : dstB;
			float dstFar  = isNearestA ? dstB : dstA;
			int childIndexNear = isNearestA ? childIndexA : childIndexB;
			int childIndexFar  = isNearestA ? childIndexB : childIndexA;

			if (dstFar  < result.dst) stack[stackIndex++] = childIndexFar;
			if (dstNear < result.dst) stack[stackIndex++] = childIndexNear;
		}
	}
	return result;
}

vec3 trace(Ray ray, inout uint rngState)
{
	vec3 rayColor = vec3(1.0f);
	vec3 incomingLight = vec3(0.0f);

	vec3 emittedLight = vec3(0.0f);
	vec3 attenuation = vec3(0.0f);

	for (int i = 0; i < maxBounceCount; i++)
	{
		HitInfo hitInfo = calculateRayCollisionBVH(ray);
		if (hitInfo.didHit)
		{
			Material material = hitInfo.material;

			if (material.materialType != GLASS)
				ray.origin = hitInfo.hitPoint - ray.direction * hitInfo.dst * -1e-6; // Offset intersection above the surface
			else 
				ray.origin = hitInfo.hitPoint + ray.direction * hitInfo.dst * -1e-6; // Offset intersection below the surface

			emittedLight *= 0.0f;
			attenuation *= 0.0f;

			switch (material.materialType)
			{
				case DIFFUSE:
				case TEXTURE:
					ray.direction = normalize(hitInfo.normal + randomDirection(rngState));
					attenuation = material.materialType == DIFFUSE ? material.color.xyz : getTriangleTextureColor(ray, triangles[hitInfo.triangleIndex], hitInfo.material.textureIndex);
					break;
				case SPECULAR:
					vec3 diffuseDirection = normalize(hitInfo.normal + randomDirection(rngState));
					vec3 specularDirection = reflect(ray.direction, hitInfo.normal);
					bool isSpecularBounce = material.specularProbability > random(rngState);

					ray.direction = mix(diffuseDirection, specularDirection, isSpecularBounce ? material.smoothness : 0.0f);
					attenuation = isSpecularBounce ? vec3(1.0f) : material.color.xyz;
					break;
				case LIGHT:
					emittedLight = material.emissionColor.xyz * material.emissionStrength;
					return emittedLight * rayColor;
				case CHECKER:
					ray.direction = normalize(hitInfo.normal + randomDirection(rngState));

					bool isBlackChecker = material.checkerScale > 0.0f
						&& (mod(floor(ray.origin.x * material.checkerScale)
						+ floor(ray.origin.y * material.checkerScale)
						+ floor(ray.origin.z * material.checkerScale), 2) == 0);

					attenuation = isBlackChecker ? vec3(0.0f) : vec3(1.0f);
					break;
				case GLASS:
					float refractiveIndex = ray.insideGlass ? material.refractiveIndex : 1.0f / material.refractiveIndex;
					bool isRefracted;
					ray.direction = refract_(ray.direction, hitInfo.normal, refractiveIndex, isRefracted);
					ray.insideGlass = isRefracted != ray.insideGlass;
					attenuation = material.color.xyz;

					break;
				default:
					return vec3(0);
			}
			rayColor *= attenuation;
		}
		else
		{
			if (environmentalLight)
				incomingLight += getEnvironmentalLight(ray) * rayColor;
			break;
		}
	}

	return incomingLight;
}

vec3 traceBasic(Ray ray)
{
	vec3 colorCumulative = vec3(0.0f);
	int bounceLimit = 20;
	int bounceCount = 0;

	for (int i = 0; i < bounceLimit; i++)
	{
		bounceCount++;
		HitInfo hitInfo = calculateRayCollisionBVH(ray);
		
		if (hitInfo.didHit)
		{
			ray.origin = hitInfo.hitPoint - hitInfo.normal * 1e-4; // Offset intersection above the surface

			if (hitInfo.material.materialType == SPECULAR)
			{
				colorCumulative += hitInfo.material.color.xyz;
				ray.direction = reflect(ray.direction, hitInfo.normal);
			}
			else if (hitInfo.material.materialType == TEXTURE || hitInfo.material.materialType == DIFFUSE)
			{
				colorCumulative += hitInfo.material.materialType == TEXTURE
								 ? getTriangleTextureColor(ray, triangles[hitInfo.triangleIndex], hitInfo.material.textureIndex)
								 : hitInfo.material.color.xyz;
				if (basicShadingShadow)
				{
					vec3 directionToLight = normalize(basicShadingLightPosition.xyz - hitInfo.hitPoint);
					Ray rayToLight;
					rayToLight.origin = ray.origin;
					rayToLight.direction = directionToLight;
					HitInfo hitInfoToLight = calculateRayCollisionBVH(rayToLight);
					return (hitInfoToLight.didHit ? colorCumulative / 5 : colorCumulative) / bounceCount; 
				}
				else
					return colorCumulative / bounceCount;
				
			}
			else
				return vec3(1.0f, 0.0f, 1.0f);
		}
		else
		{
			colorCumulative += getEnvironmentalLight(ray);
			break;
		}
	}

	return colorCumulative / bounceCount;
}

void main()
{
	vec3 color;
	// Map fragPos coordinates from [-1, 1] to [0, 4,294,967]
	uint x = uint((fragPos.x + 1.0) * 2147483647.5);
	uint y = uint((fragPos.y + 1.0) * 2147483647.5);

	uint seed = x * 3170107u + y * 160033249u + frameIndex * 968824447u;

	vec3 endPoint = cameraPos.xyz + viewportFront.xyz + viewportRight.xyz * fragPos.x + viewportUp.xyz * fragPos.y;

	if (basicShading)
	{
		Ray ray;
		ray.origin = cameraPos.xyz;
		ray.direction = normalize(viewportFront.xyz + viewportRight.xyz * fragPos.x + viewportUp.xyz * fragPos.y);
		color = traceBasic(ray);
	}
	else
	{	
		vec3 colorCumulative = vec3(0);

		for (int i = 0; i < numRaysPerPixel; i++)
		{
			Ray rayJittered;
			vec2 randDir2D = randomDirection2D(seed);
			rayJittered.origin = cameraPos.xyz + defocusDiskRight.xyz * randDir2D.x + defocusDiskUp.xyz * randDir2D.y;
			vec3 endPointJittered = endPoint + pixelRight.xyz * random(-0.5f, 0.5f, seed) + pixelUp.xyz * random(-0.5f, 0.5f, seed);
			rayJittered.direction = normalize(endPointJittered - rayJittered.origin);
			rayJittered.insideGlass = false;

			colorCumulative += trace(rayJittered, seed);
		}

		color = colorCumulative / numRaysPerPixel;
	}

	FragColor = vec4(color, 1.0f);
}