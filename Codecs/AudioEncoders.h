// MP3 (LAME) / OGG Vorbis 编码的简单 C 封装，给 Swift 调用。
// 输入统一为 32 位浮点、交错排列（LRLR…）、范围 -1.0～1.0 的 PCM。
#ifndef AUDIO_ENCODERS_H
#define AUDIO_ENCODERS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MP3Encoder MP3Encoder;
typedef struct OggEncoder OggEncoder;

/// 打开 MP3 编码器。channels 为 1 或 2，bitrateKbps 如 128/192/320（固定码率）。失败返回 NULL。
MP3Encoder *mp3enc_open(const char *path, int sampleRate, int channels, int bitrateKbps);
/// 写入 frames 帧（每帧 channels 个样本）。成功返回 0。
int mp3enc_write(MP3Encoder *enc, const float *interleaved, int frames);
/// 结束编码、写入时长信息并关闭文件。成功返回 0。无论成败都会释放 enc。
int mp3enc_finish(MP3Encoder *enc);
/// 放弃编码（关闭并释放，不写尾部）。
void mp3enc_abort(MP3Encoder *enc);

/// 打开 OGG Vorbis 编码器。quality 取 -0.1～1.0（0.4≈128k，0.6≈192k）。失败返回 NULL。
OggEncoder *oggenc_open(const char *path, int sampleRate, int channels, float quality);
int oggenc_write(OggEncoder *enc, const float *interleaved, int frames);
int oggenc_finish(OggEncoder *enc);
void oggenc_abort(OggEncoder *enc);

#ifdef __cplusplus
}
#endif
#endif
