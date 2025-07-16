#version 430 core

layout (local_size_x = 8, local_size_y = 4, local_size_z = 1) in;

layout(rgba32f, binding = 0) uniform image2D imgOutput;

const int DIFFUSE = 0;
const int SPECULAR = 1;
const int LIGHT = 2;
const int CHECKER = 3;
const int GLASS = 4;
const int TEXTURE = 5;
const int GLASS_HIGHLIGHT = 6;

const int MAX_DEPTH = 64;

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
	int isEdgeHighlight;
};

struct Sphere
{
	int mtlIndex;
	vec3 center;
	float radius;
};

struct Triangle
{
	vec3 a;
	vec3 b;
	vec3 c;
	vec2 aTex;
	vec2 bTex;
	vec2 cTex;
	int mtlIndex;
	// int pad;
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

layout(binding = 1, std430) buffer TrianglesBlock
{
	Triangle triangles[];
};

layout(binding = 2, std430) buffer NodesBlock
{
	Node allNodes[];
};

layout(binding = 3, std430) buffer MaterialsBlock
{
	Material materials[];
};

struct Ray
{
	vec3 origin;
	vec3 direction;
	bool insideGlass;
};

struct HitInfo
{
	int mtlIndex;
	bool didHit;
	vec3 hitPoint;
	vec3 normal;
	float dst;
	int triangleIndex;
	vec3 baryCoord;
};

const int MAX_TEXTURES = 5;
uniform sampler2D textures[MAX_TEXTURES];

uniform sampler2D texture0;
uniform sampler2D texture1;
uniform sampler2D texture2;
uniform sampler2D texture3;
uniform sampler2D texture4;

uniform bool qualityShading;

layout(binding = 3, std140) uniform GlobalUniformsBlock {
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
	return rho * cos(theta);
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

vec3 randomDirectionGauss(inout uint rngState)
{
	float x = randomNormalDist(rngState);
	float y = randomNormalDist(rngState);
	float z = randomNormalDist(rngState);
	return normalize(vec3(x, y, z));
}

vec3 randomDirectionAlt(inout uint state)
{
	float z = random(state) * 2.0 - 1.0;         // z in [-1, 1]
	float a = random(state) * 6.2831853;         // a in [0, 2π]
	float r = sqrt(1.0 - z * z);                 // radius in xy-plane
	return vec3(r * cos(a), r * sin(a), z);
}

vec3 randomDirectionHemisphere(vec3 normal, inout uint rngState)
{
	vec3 dir = randomDirectionAlt(rngState);
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
    // 4 PM sun position (low angle, slightly west)
    vec3 sunDir = normalize(vec3(0.6, 0.3, -0.2));
    
    // Calculate angles
    float sunDot = dot(ray.direction, sunDir);
    float horizonDot = ray.direction.y;
    
    // Sky colors with twilight progression
    vec3 zenithColor = vec3(0.15, 0.25, 0.65);
    vec3 deepOrange = vec3(1.2, 0.4, 0.1);      // Deep orange near sun horizon
    vec3 yellow = vec3(1.0, 0.8, 0.3);          // Yellow transition
    vec3 coolBlue = vec3(0.3, 0.4, 0.7);        // Cool blue opposite side
    vec3 groundColor = vec3(0.2, 0.15, 0.1);
    
    // Create twilight horizon gradient: deep orange -> yellow -> blue
    float sunToOpposite = (dot(ray.direction, -sunDir) + 1.0) * 0.5;  // 0 = sun side, 1 = opposite side
    vec3 horizonColor;
    if (sunToOpposite < 0.5) {
        // Sun side: deep orange to yellow
        horizonColor = mix(deepOrange, yellow, sunToOpposite * 2.0);
    } else {
        // Opposite side: yellow to blue
        horizonColor = mix(yellow, coolBlue, (sunToOpposite - 0.5) * 2.0);
    }
    
    // Vertical sky gradient
    float skyGradient = smoothstep(-0.2, 0.8, horizonDot);
    vec3 baseColor = mix(horizonColor, zenithColor, skyGradient);
    
    // Tighter sun glow - much smaller disk
    vec3 sunCenter = vec3(15.0, 15.0, 10.0);
    float sunAngle = acos(clamp(sunDot, -1.0, 1.0));
    
    // Slightly bigger sun glow
    float glow1 = exp(-sunAngle * 600.0);        // Tight core (reduced from 800)
    float glow2 = exp(-sunAngle * 150.0) * 0.3;  // Small bright ring (reduced from 200)
    float glow3 = exp(-sunAngle * 60.0) * 0.1;   // Medium falloff (reduced from 80)
    float glow4 = exp(-sunAngle * 15.0) * 0.03;  // Soft outer glow (reduced from 20)
    
    float totalGlow = glow1 + glow2 + glow3 + glow4;
    
    // Apply sun glow
    vec3 finalColor = baseColor + sunCenter * totalGlow;
    
    // Ground handling
    if (horizonDot < 0.0) {
        float groundBlend = smoothstep(-0.1, 0.0, horizonDot);
        finalColor = mix(groundColor, finalColor, groundBlend);
        
        // Subtle ground illumination
        float groundSunGlow = exp(-sunAngle * 15.0) * 0.2;
        finalColor += sunCenter * groundSunGlow * 0.05;
    }
    
    return finalColor;
}

HitInfo raySphereIntersect(Ray ray, Sphere sphere)
{
	vec3 rayOriginTrans = ray.origin - sphere.center;
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
			hitInfo.mtlIndex = sphere.mtlIndex;
		}
	}

	return hitInfo;
}

HitInfo rayTriangleIntersect(Ray ray, Triangle tri)
{
	HitInfo hitInfo;
	hitInfo.didHit = false;

	vec3 e0 = tri.b - tri.a;
	vec3 e1 = tri.c - tri.a;
	vec3 cross01 = cross(e0, e1);
	float det = -dot(ray.direction, cross01);

	if (det < 1e-10f && det > -1e-10f || det < 0)
		return hitInfo;
	
	float invDet = 1.0f / det;
	vec3 ao = ray.origin - tri.a;
	float dst = dot(ao, cross01) * invDet;

	if (dst <= 1e-6)
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
	hitInfo.mtlIndex = tri.mtlIndex;

	float w = 1.0f - u - v;
    hitInfo.baryCoord = vec3(w, u, v);
	
	return hitInfo;
}

vec3 getTriangleTextureColor(int textureIndex, vec3 baryCoord, vec2 aTex, vec2 bTex, vec2 cTex)
{
	vec2 uv = aTex * baryCoord.x + bTex * baryCoord.y + cTex * baryCoord.z;

	// Use if-else to select the correct texture
    if (textureIndex == 0)
        return texture(texture0, uv).rgb;
    else if (textureIndex == 1)
        return texture(texture1, uv).rgb;
    else if (textureIndex == 2)
        return texture(texture2, uv).rgb;
    else if (textureIndex == 3)
        return texture(texture3, uv).rgb;
    else if (textureIndex == 4)
        return texture(texture4, uv).rgb;
    else
        return vec3(1.0f, 0.0f, 1.0f); // Return magenta if something goes wrong
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
				HitInfo hitInfo = rayTriangleIntersect(ray, triangles[i]);
				if (hitInfo.didHit)
					if (hitInfo.dst < result.dst)
					{
						result = hitInfo;
						result.triangleIndex = i;
					}
			}
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

vec3 normalizeColor(vec3 color) {
    float maxComponent = max(max(color.r, color.g), color.b);

    if (maxComponent > 1.0) {
        return color / maxComponent;
    }

    return color;
}

vec3 trace(Ray ray, inout uint rngState)
{
	vec3 rayColor = vec3(1.0f);
	vec3 incomingLight = vec3(0.0f);

	vec3 emittedLight = vec3(0.0f);
	vec3 attenuation = vec3(0.0f);
	int bounceCount = 0;

	while (bounceCount < maxBounceCount)
	{
		bounceCount++;
		HitInfo hitInfo = calculateRayCollisionBVH(ray);
		if (hitInfo.didHit)
		{
			Material material = materials[hitInfo.mtlIndex];

			emittedLight *= 0.0f;
			attenuation *= 0.0f;

			vec3 prevDirection = ray.direction;
			vec3 specularDirection = reflect(ray.direction, hitInfo.normal);

            bool isSpecularBounce = material.specularProbability > random(rngState);
            if (isSpecularBounce)
            {
                ray.direction = specularDirection;
                attenuation = material.specularColor.xyz;
            }
			else if (material.refractiveIndex > 0.999999)
			{
				float refractiveIndex = ray.insideGlass ? material.refractiveIndex : 1.0f / material.refractiveIndex;

				vec3 normal = hitInfo.normal;
				if (ray.insideGlass)
					normal = -normal;

				bool isRefracted;
				ray.direction = refract_(ray.direction, normal, refractiveIndex, isRefracted);

				ray.insideGlass = ray.insideGlass != isRefracted;
				attenuation = material.color.xyz;
			}
			else
			{
				vec3 diffuseDirection = normalize(hitInfo.normal + randomDirectionAlt(rngState));
                ray.direction = mix(diffuseDirection, specularDirection, material.smoothness);
				Triangle tri = triangles[hitInfo.triangleIndex];
				attenuation = material.textureIndex != -1 ? getTriangleTextureColor(material.textureIndex, hitInfo.baryCoord, tri.aTex, tri.bTex, tri.cTex) : material.color.xyz;
			}

			vec3 emittedLight = material.emissionColor.xyz * material.emissionStrength;
            incomingLight += emittedLight * rayColor;

			if (bool(material.isEdgeHighlight) && (bounceCount > 1))
				ray.direction = prevDirection;
			else
				rayColor *= attenuation;

			ray.origin = hitInfo.hitPoint + ray.direction * 1e-3;

			// A simple optimization
			float p = max(rayColor.r, max(rayColor.g, rayColor.b));
			if (random(rngState) > p)
				break;
			rayColor *= 1.0f / p;
		}
		else
		{
			if (environmentalLight)
				incomingLight += getEnvironmentalLight(ray) * rayColor;
			return incomingLight;
		}
	}

	return incomingLight;
}

vec3 traceBasic(Ray ray)
{
	vec3 colorCumulative = vec3(0.0f);
	int bounceLimit = 20;
	int bounceCount = 0;

	while (bounceCount < maxBounceCount)
	{
		bounceCount++;
		HitInfo hitInfo = calculateRayCollisionBVH(ray);
		
		if (hitInfo.didHit)
		{
			ray.origin = hitInfo.hitPoint - hitInfo.normal * 1e-4; // Offset intersection above the surface
			Material material = materials[hitInfo.mtlIndex];
			switch (material.materialType)
			{
			case SPECULAR:
				colorCumulative += material.color.xyz;
				ray.direction = reflect(ray.direction, hitInfo.normal);
				break;
			case DIFFUSE:
			case TEXTURE:
			case CHECKER:
				vec3 color;
				switch (material.materialType)
				{
				case TEXTURE:
					Triangle tri = triangles[hitInfo.triangleIndex];
					color = getTriangleTextureColor(material.textureIndex, hitInfo.baryCoord, tri.aTex, tri.bTex, tri.cTex);
					break;
				case DIFFUSE:
					color = material.color.xyz;
					break;
				case CHECKER:
					bool isBlackChecker = material.checkerScale > 0.0f
						&& (mod(floor(ray.origin.x * material.checkerScale)
						+ floor(ray.origin.y * material.checkerScale)
						+ floor(ray.origin.z * material.checkerScale), 2) == 0);
					color = isBlackChecker ? vec3(0.0f) : vec3(1.0f);
				}

				colorCumulative += color;

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
			case LIGHT:
				return normalizeColor(material.emissionColor.xyz);
			case GLASS:
				float refractiveIndex = ray.insideGlass ? material.refractiveIndex : 1.0f / material.refractiveIndex;
				bool isRefracted;
				ray.direction = refract_(ray.direction, hitInfo.normal, refractiveIndex, isRefracted);
				ray.insideGlass = isRefracted != ray.insideGlass;
				colorCumulative = material.color.xyz;
				break;
			case GLASS_HIGHLIGHT:
				if (bounceCount == 0)
					colorCumulative = material.color.xyz;
				break;
			default:
				return vec3(1.0f, 0.0f, 1.0f);
			}
		}
		else
		{
			colorCumulative += getEnvironmentalLight(ray);
			break;
		}
	}

	return colorCumulative / bounceCount;
}

vec3 tonemapACES(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

vec3 toSRGB(vec3 linearRGB) {
	return pow(linearRGB, vec3(1.0 / 2.2));
}

void main()
{
    vec3 color = vec3(1.0f);
	ivec2 texelCoord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(imgOutput);
	float x = float(texelCoord.x * 2 - size.x) / size.x;
	float y = float(texelCoord.y * 2 - size.y) / size.y;

	uint seed = texelCoord.x + texelCoord.y * size.x + frameIndex * 968824447u;

	vec3 endPoint = cameraPos.xyz + viewportFront.xyz + viewportRight.xyz * x + viewportUp.xyz * y;

	if (basicShading)
	{
		Ray ray;
		ray.origin = cameraPos.xyz;
		ray.direction = normalize(viewportFront.xyz + viewportRight.xyz * x + viewportUp.xyz * y);
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
			// colorCumulative += traceBasic(rayJittered);
		}

		color = colorCumulative / numRaysPerPixel;
		color = toSRGB(tonemapACES(color));
	}

	imageStore(imgOutput, texelCoord, vec4(color, 1.0f));
}