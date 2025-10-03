shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float freeze_amount : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

vec4 _sample_screen(vec2 uv) {
    return texture(screen_texture, clamp(uv, vec2(0.0), vec2(1.0)));
}

void fragment() {
    vec4 base_color = _sample_screen(SCREEN_UV);
    vec3 final_rgb = base_color.rgb;

    if (intensity > 0.0001) {
        float eased_intensity = pow(intensity, 0.8);
        vec2 center = vec2(0.5);
        vec2 dir = SCREEN_UV - center;
        float dist = length(dir);
        vec2 dir_norm = dist < 0.0001 ? vec2(0.0) : dir / dist;
        float chroma_spread = eased_intensity * (0.015 + dist * 0.02);
        float jitter = sin(TIME * 8.0 + dist * 28.0);
        vec2 chroma_offset = dir_norm * chroma_spread * (1.0 + jitter * 0.45);
        vec3 chroma_color;
        chroma_color.r = _sample_screen(SCREEN_UV + chroma_offset * 1.15).r;
        chroma_color.g = _sample_screen(SCREEN_UV + chroma_offset * -0.35).g;
        chroma_color.b = _sample_screen(SCREEN_UV - chroma_offset * 1.05).b;
        float smear_distance = chroma_spread * (2.0 + jitter * 0.5);
        vec4 smear = vec4(0.0);
        smear += _sample_screen(SCREEN_UV + dir_norm * smear_distance * 0.25);
        smear += _sample_screen(SCREEN_UV - dir_norm * smear_distance * 0.25);
        smear += _sample_screen(SCREEN_UV + dir_norm * smear_distance * 0.55);
        smear += _sample_screen(SCREEN_UV - dir_norm * smear_distance * 0.55);
        smear *= 0.25;
        float stretch_mix = clamp(eased_intensity * 1.1, 0.0, 1.0);
        vec3 mixed_rgb = mix(base_color.rgb, chroma_color, stretch_mix);
        mixed_rgb = mix(mixed_rgb, smear.rgb, eased_intensity * (0.55 + dist * 0.35));
        float speed_streak = eased_intensity * (0.2 + dist * 0.6);
        vec2 streak_uv = SCREEN_UV + dir_norm * speed_streak * 0.02;
        vec4 streak_color = _sample_screen(streak_uv);
        mixed_rgb = mix(mixed_rgb, streak_color.rgb, eased_intensity * 0.35);
        float glow = 1.0 + eased_intensity * 0.18 + jitter * 0.06 * eased_intensity;
        final_rgb = mixed_rgb * glow;
    }

    float freeze = clamp(freeze_amount, 0.0, 1.0);
    if (freeze > 0.0001) {
        float eased_freeze = pow(freeze, 0.85);
    vec3 desaturated = vec3(dot(final_rgb, vec3(0.299, 0.587, 0.114)));
    vec3 frost_tint = mix(desaturated, vec3(1.0), eased_freeze * 0.5);
        float vignette = smoothstep(0.2, 0.95, length(SCREEN_UV - vec2(0.5)));
    final_rgb = mix(final_rgb, frost_tint, eased_freeze * 0.6);
    final_rgb *= mix(1.0, 1.09, eased_freeze);
    final_rgb = mix(final_rgb, final_rgb * (1.0 - vignette * 0.35 * eased_freeze), eased_freeze * 0.325);
    }

    COLOR = vec4(final_rgb, base_color.a);
}
