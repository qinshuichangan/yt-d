#include "AudioEncoders.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "lame.h"
#include <vorbis/vorbisenc.h>

// ===================== MP3 =====================

struct MP3Encoder {
    lame_global_flags *lame;
    FILE *file;
    int channels;
    unsigned char *buf;
    int bufSize;
};

static void mp3_free(MP3Encoder *enc) {
    if (!enc) return;
    if (enc->lame) lame_close(enc->lame);
    if (enc->file) fclose(enc->file);
    free(enc->buf);
    free(enc);
}

MP3Encoder *mp3enc_open(const char *path, int sampleRate, int channels, int bitrateKbps) {
    if (channels < 1 || channels > 2) return NULL;
    MP3Encoder *enc = calloc(1, sizeof(MP3Encoder));
    if (!enc) return NULL;
    enc->channels = channels;
    enc->file = fopen(path, "w+b");   // w+ 是为了最后回头写 LAME/Xing 标签
    enc->lame = lame_init();
    if (!enc->file || !enc->lame) { mp3_free(enc); return NULL; }

    lame_set_num_channels(enc->lame, channels);
    lame_set_in_samplerate(enc->lame, sampleRate);
    lame_set_out_samplerate(enc->lame, sampleRate);
    lame_set_mode(enc->lame, channels == 1 ? MONO : JOINT_STEREO);
    lame_set_brate(enc->lame, bitrateKbps);
    lame_set_VBR(enc->lame, vbr_off);
    lame_set_quality(enc->lame, 2);          // 2 = 高质量（0 最好最慢，9 最差）
    lame_set_bWriteVbrTag(enc->lame, 1);     // 写入 Info 帧，播放器能显示准确时长
    if (lame_init_params(enc->lame) < 0) { mp3_free(enc); return NULL; }
    return enc;
}

static int mp3_ensure_buf(MP3Encoder *enc, int frames) {
    // LAME 文档建议：1.25 * 样本数 + 7200
    int need = (int)(1.25 * frames) + 7200;
    if (need <= enc->bufSize) return 0;
    unsigned char *nb = realloc(enc->buf, need);
    if (!nb) return -1;
    enc->buf = nb;
    enc->bufSize = need;
    return 0;
}

int mp3enc_write(MP3Encoder *enc, const float *pcm, int frames) {
    if (!enc || frames <= 0) return 0;
    if (mp3_ensure_buf(enc, frames) != 0) return -1;
    int n;
    if (enc->channels == 2) {
        n = lame_encode_buffer_interleaved_ieee_float(enc->lame, pcm, frames, enc->buf, enc->bufSize);
    } else {
        n = lame_encode_buffer_ieee_float(enc->lame, pcm, pcm, frames, enc->buf, enc->bufSize);
    }
    if (n < 0) return n;
    if (n > 0 && fwrite(enc->buf, 1, (size_t)n, enc->file) != (size_t)n) return -1;
    return 0;
}

int mp3enc_finish(MP3Encoder *enc) {
    if (!enc) return -1;
    int rc = 0;
    if (mp3_ensure_buf(enc, 0) != 0) rc = -1;
    if (rc == 0) {
        int n = lame_encode_flush(enc->lame, enc->buf, enc->bufSize);
        if (n < 0) rc = n;
        else if (n > 0 && fwrite(enc->buf, 1, (size_t)n, enc->file) != (size_t)n) rc = -1;
    }
    if (rc == 0) {
        fflush(enc->file);
        lame_mp3_tags_fid(enc->lame, enc->file);
        if (fflush(enc->file) != 0) rc = -1;
    }
    mp3_free(enc);
    return rc;
}

void mp3enc_abort(MP3Encoder *enc) { mp3_free(enc); }

// ===================== OGG Vorbis =====================

struct OggEncoder {
    FILE *file;
    int channels;
    int ready;            // vorbis 结构都已初始化
    ogg_stream_state os;
    ogg_page og;
    ogg_packet op;
    vorbis_info vi;
    vorbis_comment vc;
    vorbis_dsp_state vd;
    vorbis_block vb;
};

static int ogg_write_page(OggEncoder *enc, ogg_page *page) {
    if (fwrite(page->header, 1, (size_t)page->header_len, enc->file) != (size_t)page->header_len) return -1;
    if (fwrite(page->body, 1, (size_t)page->body_len, enc->file) != (size_t)page->body_len) return -1;
    return 0;
}

static void ogg_free(OggEncoder *enc) {
    if (!enc) return;
    if (enc->ready) {
        ogg_stream_clear(&enc->os);
        vorbis_block_clear(&enc->vb);
        vorbis_dsp_clear(&enc->vd);
        vorbis_comment_clear(&enc->vc);
    }
    vorbis_info_clear(&enc->vi);
    if (enc->file) fclose(enc->file);
    free(enc);
}

OggEncoder *oggenc_open(const char *path, int sampleRate, int channels, float quality) {
    if (channels < 1 || channels > 2) return NULL;
    OggEncoder *enc = calloc(1, sizeof(OggEncoder));
    if (!enc) return NULL;
    enc->channels = channels;
    vorbis_info_init(&enc->vi);
    if (vorbis_encode_init_vbr(&enc->vi, channels, sampleRate, quality) != 0) { ogg_free(enc); return NULL; }
    enc->file = fopen(path, "wb");
    if (!enc->file) { ogg_free(enc); return NULL; }

    vorbis_comment_init(&enc->vc);
    vorbis_comment_add_tag(&enc->vc, "ENCODER", "VideoTool (libvorbis)");
    vorbis_analysis_init(&enc->vd, &enc->vi);
    vorbis_block_init(&enc->vd, &enc->vb);
    srand((unsigned)time(NULL));
    ogg_stream_init(&enc->os, rand());
    enc->ready = 1;

    ogg_packet header, header_comm, header_code;
    vorbis_analysis_headerout(&enc->vd, &enc->vc, &header, &header_comm, &header_code);
    ogg_stream_packetin(&enc->os, &header);
    ogg_stream_packetin(&enc->os, &header_comm);
    ogg_stream_packetin(&enc->os, &header_code);
    // 头部单独成页，保证音频数据从新页开始
    while (ogg_stream_flush(&enc->os, &enc->og) != 0) {
        if (ogg_write_page(enc, &enc->og) != 0) { ogg_free(enc); return NULL; }
    }
    return enc;
}

static int ogg_drain(OggEncoder *enc) {
    while (vorbis_analysis_blockout(&enc->vd, &enc->vb) == 1) {
        vorbis_analysis(&enc->vb, NULL);
        vorbis_bitrate_addblock(&enc->vb);
        while (vorbis_bitrate_flushpacket(&enc->vd, &enc->op)) {
            ogg_stream_packetin(&enc->os, &enc->op);
            while (ogg_stream_pageout(&enc->os, &enc->og) != 0) {
                if (ogg_write_page(enc, &enc->og) != 0) return -1;
                if (ogg_page_eos(&enc->og)) return 0;
            }
        }
    }
    return 0;
}

int oggenc_write(OggEncoder *enc, const float *pcm, int frames) {
    if (!enc || frames <= 0) return 0;
    float **buffer = vorbis_analysis_buffer(&enc->vd, frames);
    int ch = enc->channels;
    for (int i = 0; i < frames; i++) {
        for (int c = 0; c < ch; c++) {
            buffer[c][i] = pcm[i * ch + c];
        }
    }
    vorbis_analysis_wrote(&enc->vd, frames);
    return ogg_drain(enc);
}

int oggenc_finish(OggEncoder *enc) {
    if (!enc) return -1;
    vorbis_analysis_wrote(&enc->vd, 0);   // 通知结束，最后一页带 EOS
    int rc = ogg_drain(enc);
    if (rc == 0 && fflush(enc->file) != 0) rc = -1;
    ogg_free(enc);
    return rc;
}

void oggenc_abort(OggEncoder *enc) { ogg_free(enc); }
