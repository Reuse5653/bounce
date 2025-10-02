shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

void fragment() {
    vec2 offset = SCREEN_PIXEL_SIZE * (2.0 + intensity * 6.0);
    vec4 base = texture(screen_texture, SCREEN_UV);
    if (intensity <= 0.001) {
        COLOR = base;
        return;
    }
    vec4 accum = base;
    accum += texture(screen_texture, SCREEN_UV + vec2(offset.x, 0.0));
    accum += texture(screen_texture, SCREEN_UV - vec2(offset.x, 0.0));
    accum += texture(screen_texture, SCREEN_UV + vec2(0.0, offset.y));
    accum += texture(screen_texture, SCREEN_UV - vec2(0.0, offset.y));
    accum += texture(screen_texture, SCREEN_UV + offset);
    accum += texture(screen_texture, SCREEN_UV - offset);
    accum += texture(screen_texture, SCREEN_UV + vec2(offset.x, -offset.y));
    accum += texture(screen_texture, SCREEN_UV + vec2(-offset.x, offset.y));
    accum /= 9.0;
    COLOR = mix(base, accum, intensity);
}
