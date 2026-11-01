// @layer(audio)
// @forbid_import("os", "fmt", "net")
package audio_dsp

// Real-time audio callback example: must never allocate on either `context.allocator`
// or `context.temp_allocator` so the OS audio thread never blocks on a mutex.

Biquad_Filter :: struct {
	b0, b1, b2: f32,
	a1, a2:     f32,
	z1, z2:     f32,
}

Audio_Voice :: struct {
	samples: [256]f32,
	gain:    f32,
	active:  bool,
}

// @zero_alloc
// @no_temp_alloc
process_biquad :: proc(f: ^Biquad_Filter, sample: f32) -> f32 {
	out := f.b0 * sample + f.z1
	f.z1 = f.b1 * sample - f.a1 * out + f.z2
	f.z2 = f.b2 * sample - f.a2 * out
	return out
}

// @zero_alloc
// @no_temp_alloc
mix_voice :: proc(#by_ptr voice: Audio_Voice, filter: ^Biquad_Filter, output: []f32) {
	if !voice.active {
		return
	}
	n := min(len(output), len(voice.samples))
	for i in 0 ..< n {
		filtered := process_biquad(filter, voice.samples[i])
		output[i] += filtered * voice.gain
	}
}

// @zero_alloc
// @no_temp_alloc
audio_render_callback :: proc(voices: []Audio_Voice, filter: ^Biquad_Filter, out_buffer: []f32) {
	for i in 0 ..< len(out_buffer) {
		out_buffer[i] = 0
	}
	for &v in voices {
		mix_voice(v, filter, out_buffer)
	}
}
