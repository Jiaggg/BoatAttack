﻿#ifndef WATER_COMMON_INCLUDED
#define WATER_COMMON_INCLUDED

#define _SHADOWS_SOFT
#define _SHADOWS_ENABLED

#include "LWRP/ShaderLibrary/Core.hlsl"
#include "WaterInput.hlsl"
#include "CommonUtilities.hlsl"
#include "GerstnerWaves.cginc"
#include "WaterLighting.hlsl"

///////////////////////////////////////////////////////////////////////////////
//                  				Structs		                             //
///////////////////////////////////////////////////////////////////////////////

struct WaterVertexInput // vert struct 
{
	float4	vertex 					: POSITION;		// vertex positions
	float2	texcoord 				: TEXCOORD0;	// local UVs
	float4	lightmapUV 				: TEXCOORD1;	// lightmap UVs
	float4	color					: COLOR;		// vertex colors
};

struct WaterVertexOutput // fragment struct
{
	float4	uv 						: TEXCOORD0;	// Geometric UVs stored in xy, and world(pre-waves) in zw
	float4	lightmapUVOrVertexSH	: TEXCOORD1;	// holds either lightmapUV or vertex SH. depending on LIGHTMAP_ON - TODO
	float3	posWS					: TEXCOORD2;	// world position of the vertices
	half3 	normal 					: NORMAL;		// vert normals

	float3 	viewDir 				: TEXCOORD3;	// view direction
	float2	preWaveSP 				: TEXCOORD4;	// screen position of the verticies before wave distortion
	half4 	fogFactorAndVertexLight : TEXCOORD5;	// x: fogFactor, yzw: vertex light

	half4	additionalData			: TEXCOORD6;	// x = distance to surface, y = distance to surface??
	half4	vertColor				: TEXCOORD7;
	half4	shadowCoord				: TEXCOORD8;	// for ssshadows

	float4	clipPos					: SV_POSITION;
};

///////////////////////////////////////////////////////////////////////////////
//          	   	      Water shading functions                            //
///////////////////////////////////////////////////////////////////////////////

half3 Scattering(half depth)
{
	return _AbsorptionScatteringRamp.Sample(sampler_AbsorptionScatteringRamp, half2(saturate(depth * 0.01), 1));
}

half3 Absorption(half depth)
{
	return _AbsorptionScatteringRamp.Sample(sampler_AbsorptionScatteringRamp, half2(saturate(depth * 0.01), 0));
}

half2 WaterDepth(half3 posWS, half3 viewDir, half2 texcoords, half4 additionalData, half2 screenUVs)// x = seafloor depth, y = water depth
{
	half2 outDepth = 0;
	half d = _CameraDepthTexture.Sample(sampler_CameraDepthTexture, screenUVs).r;
	outDepth.x = LinearEyeDepth(d, _ZBufferParams) * additionalData.x - additionalData.y;
	half wd = 1-_WaterDepthMap.Sample(sampler_WaterDepthMap, texcoords).r;
	outDepth.y = ((wd * _depthCamZParams.y) - 4 - _depthCamZParams.x) + posWS.y;
	return outDepth;
}

//temp
inline float3 ObjSpaceViewDir( in float4 v )
{
    float3 objSpaceCameraPos = GetCameraPositionWS(); //mul(GetWorldToObjectMatrix(), float4(GetCameraPositionWS(), 1)).xyz;
    return objSpaceCameraPos - v.xyz;
}

///////////////////////////////////////////////////////////////////////////////
//               	   Vertex and Fragment functions                         //
///////////////////////////////////////////////////////////////////////////////

// Vertex: Used for Standard non-tessellated water
WaterVertexOutput WaterVertex(WaterVertexInput v)
{
    WaterVertexOutput o = (WaterVertexOutput)0;

    o.uv.xy = v.texcoord; // geo uvs

	// initializes o.normal
    o.normal = float3(0, 1, 0);

    o.posWS = TransformObjectToWorld(v.vertex.xyz);
	o.uv.zw = o.posWS.xz;
	o.vertColor = v.color;

	//Gerstner here
#if defined (_PERF_GERSTNER) // PERF
	WaveStruct wave;
	SampleWaves(o.posWS, 1, wave);
	o.normal = normalize(wave.normal.xzy);
	o.posWS += wave.position;
#endif


	//after waves
	o.clipPos = TransformWorldToHClip(o.posWS);
	o.shadowCoord = ComputeScreenPos(o.clipPos);
    o.viewDir = SafeNormalize(_WorldSpaceCameraPos - o.posWS);

    // We either sample GI from lightmap or SH. lightmap UV and vertex SH coefficients
    // are packed in lightmapUVOrVertexSH to save interpolator.
    // The following funcions initialize
    OUTPUT_LIGHTMAP_UV(v.lightmapUV, unity_LightmapST, o.lightmapUVOrVertexSH);
    OUTPUT_SH(o.normal, o.lightmapUVOrVertexSH);

    o.fogFactorAndVertexLight = VertexLightingAndFog(o.normal, o.posWS, o.clipPos);

	// Additional data
    //float3 viewPos = TransformWorldToView(o.posWS.xyz);
	//o.additionalData.x = length(viewPos / viewPos.z);// distance to surface
    o.additionalData.y = length(ObjSpaceViewDir(half4(o.posWS, 1)));

    return o;
}

// Fragment for water
half4 WaterFragment(WaterVertexOutput IN) : SV_Target
{
#if defined (_PERF_VERT) // PERF
	half4 screenUV = IN.shadowCoord;//screen UVs
	screenUV.xyz /= screenUV.w;
	half3 prePosWS = IN.posWS;

	half4 waterFX = _WaterFXMap.Sample(sampler_WaterFXMap, screenUV.xy);

	half3 normalWS = IN.normal;
	
	// Additional data(in vertex otherwise)
#if !_TESSELLATION // additionalData.x needs more acuracy when not tessellated
	half3 viewPos = TransformWorldToView(IN.posWS);
	IN.additionalData.x = length(viewPos / viewPos.z);// distance to surface
#endif

	//Detail waves
	half t = _Time.x;
	half3 detailBump = UnpackNormal(_BumpMap.Sample(sampler_BumpMap, IN.uv.zw * 0.05 + (t * 0.25)));
	detailBump += UnpackNormal(_BumpMap.Sample(sampler_BumpMap, (IN.uv.zw * 0.15) + (detailBump.xy * 0.01) - t));

	normalWS += half3(detailBump.x, 0, detailBump.y) * _BumpScale;

	// Depth
#if defined (_PERF_DEPTH) // PERF
	half2 depth = WaterDepth(IN.posWS, IN.viewDir, (IN.posWS.xz * 0.001) + 0.5, IN.additionalData, screenUV.xy);// TODO - hardcoded shore depth UVs
#else
	half2 depth = 100;
#endif

	// Fresnel
#if defined (_PERF_FRESNEL) // PERF
	half fresnelTerm = CalculateFresnelTerm(lerp(normalWS, half3(0, 1, 0), 0.5), IN.viewDir.xyz);
#else
	half fresnelTerm = 0;
#endif

	// Shadows
	half shadow = SampleShadowmap(ComputeScreenSpaceShadowCoords(IN.posWS));

	// Do diffuse/fog?
    //half3 indirectDiffuse = SampleGI(IN.lightmapUVOrVertexSH, normalWS);
    float fogFactor = IN.fogFactorAndVertexLight.x;
	
	// Do specular
#if defined (_PERF_LIGHTING) // PERF
	half3 spec = Highlights(IN.posWS, 0.01, normalWS, IN.viewDir) * shadow;	
#else
	half3 spec = 0;
#endif

	// Do reflections
#if defined (_PERF_REF) // PERF
	half3 reflection = SampleReflections(normalWS, IN.viewDir.xyz, screenUV, fresnelTerm, 0.0);
#else
	half3 reflection = 0;
#endif
	reflection = max(reflection, spec);

	// Do Refractions
	//half3 refraction = _CameraColorTexture.Sample(sampler_CameraColorTexture, screenUV);

	// Do Foam
#if defined (_PERF_FOAM) // PERFpth.y
	half3 foamMap = _FoamMap.Sample(sampler_FoamMap, (IN.uv.zw * 0.025) + (detailBump.xy * 0.0025)); //r=thick, g=medium, b=light
	half shoreMask = saturate((1-depth.y + 1.25) * 0.35);//shore foam
	
	half foamMask = IN.posWS.y - 0.5;
	foamMask = saturate(foamMask + shoreMask + waterFX.r);
	half3 foamBlend = _FoamBlend.Sample(sampler_FoamBlend, half2(foamMask, 0.5));

	half foam = length(foamMap * foamBlend);
#else
	half foam = 0;
#endif

	// Do colouring
    half3 color = 1;// TODO - get scene colour
#if defined (_PERF_COL) // PERF
	color *= Absorption(depth.x);// TODO - absoption
	color += Scattering(depth.x);// TODO - scattering
	color *= saturate(min(shadow + 0.2, 1-fresnelTerm));
#else
	color = 0.5;
#endif

	// Do compositing
	half3 comp = color + (foam * 0.75) + (reflection * (1-(foam)));
    // Computes fog factor per-vertex
    ApplyFog(comp, fogFactor);

	//DebugViews
#if _DEBUG
	if(_DebugPass == 1)
	{
		return half4(reflection, 1); // Reflection debug
	}
	else if(_DebugPass == 2) // Color debug
	{
		return half4(color, 1);
	}
	else if(_DebugPass == 3) // Depth debug
	{
		return half4(depth, 0, 1);
	}
	else if(_DebugPass == 4) // WaterFX pass debug
	{
		return waterFX;
	}
	else if(_DebugPass == 5) // Normals debug
	{
		return half4(normalWS, 1);
	}
	else if(_DebugPass == 6) // Fresnel debug
	{
		return half4(fresnelTerm, 0, 0, 1);
	}
	else if(_DebugPass == 7) // Specular debug
	{
		return half4(spec, 1);
	}
	else if(_DebugPass == 8) // Temp debug
	{
		return half4(frac(IN.clipPos.xy), 0, 1);
	}
	else // fallback to output
	{
		return half4(comp, 1);
	}
#else
	return half4(comp, 1);
#endif
#else // vert perf
	return half4(0.5, 0.5, 0.5, 1);
#endif
}

#endif // WATER_COMMON_INCLUDED