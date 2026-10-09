/*
 * libvorbis encoder shim TU.
 *
 * Zig 0.17 removed @cImport, and the libogg/libvorbis encode state
 * (vorbis_info, vorbis_comment, vorbis_dsp_state, vorbis_block,
 * ogg_stream_state) is caller-allocated with no size-query API, so the Zig
 * side cannot hold it as opaque blobs. The miniaudio zc_* pattern applies
 * here the same way: the five structs live inside one C struct in this TU,
 * and src/ninjam/vorbis.zig drives the same encode loop it always did
 * through the zc_venc_* entry points below. Only ogg_page and ogg_packet
 * cross the boundary — small POD out-params whose layouts the Zig side
 * mirrors (ogg.h:26-47, 89-102; ABI-stable upstream for decades).
 */
#include <stdlib.h>
#include <string.h>
#include <ogg/ogg.h>
#include <vorbis/codec.h>
#include <vorbis/vorbisenc.h>

typedef struct
{
    vorbis_info vi;
    vorbis_comment vc;
    vorbis_dsp_state vd;
    vorbis_block vb;
    ogg_stream_state os;
    /* how far create() got; destroy() clears only what was inited */
    int stage;
} zc_venc;

void zc_venc_destroy(zc_venc *e);

zc_venc *zc_venc_create(long rate, float quality, int serial)
{
    zc_venc *e = malloc(sizeof(*e));
    if (e == NULL) {
        return NULL;
    }
    memset(e, 0, sizeof(*e));
    e->stage = 0;
    vorbis_info_init(&e->vi);
    e->stage = 1;
    if (vorbis_encode_init_vbr(&e->vi, 1, rate, quality) != 0) {
        goto fail;
    }
    vorbis_comment_init(&e->vc);
    e->stage = 2;
    vorbis_comment_add_tag(&e->vc, "ENCODER", "zclient");
    if (vorbis_analysis_init(&e->vd, &e->vi) != 0) {
        goto fail;
    }
    e->stage = 3;
    if (vorbis_block_init(&e->vd, &e->vb) != 0) {
        goto fail;
    }
    e->stage = 4;
    if (ogg_stream_init(&e->os, serial) != 0) {
        goto fail;
    }
    e->stage = 5;
    return e;
fail:
    zc_venc_destroy(e);
    return NULL;
}

void zc_venc_destroy(zc_venc *e)
{
    if (e == NULL) {
        return;
    }
    /* same clear order the Zig Encoder used */
    if (e->stage >= 3) vorbis_dsp_clear(&e->vd);
    if (e->stage >= 4) vorbis_block_clear(&e->vb);
    if (e->stage >= 2) vorbis_comment_clear(&e->vc);
    if (e->stage >= 1) vorbis_info_clear(&e->vi);
    if (e->stage >= 5) ogg_stream_clear(&e->os);
    free(e);
}

/* The 3 header packets (id/comment/setup) into the stream state. */
void zc_venc_headers(zc_venc *e)
{
    ogg_packet ident, comm, code;
    vorbis_analysis_headerout(&e->vd, &e->vc, &ident, &comm, &code);
    ogg_stream_packetin(&e->os, &ident);
    ogg_stream_packetin(&e->os, &comm);
    ogg_stream_packetin(&e->os, &code);
}

/* The mono input buffer for `samples` frames — channel 0 of the
 * float** the libvorbis API hands back. */
float *zc_venc_buffer(zc_venc *e, int samples)
{
    return vorbis_analysis_buffer(&e->vd, samples)[0];
}

void zc_venc_wrote(zc_venc *e, int samples)
{
    vorbis_analysis_wrote(&e->vd, samples);
}

int zc_venc_blockout(zc_venc *e)
{
    return vorbis_analysis_blockout(&e->vd, &e->vb);
}

void zc_venc_analysis(zc_venc *e)
{
    vorbis_analysis(&e->vb, NULL);
}

void zc_venc_addblock(zc_venc *e)
{
    vorbis_bitrate_addblock(&e->vb);
}

int zc_venc_flushpacket(zc_venc *e, ogg_packet *op)
{
    return vorbis_bitrate_flushpacket(&e->vd, op);
}

void zc_venc_packetin(zc_venc *e, const ogg_packet *op)
{
    ogg_stream_packetin(&e->os, (ogg_packet *)op);
}

int zc_venc_pageout(zc_venc *e, ogg_page *og)
{
    return ogg_stream_pageout(&e->os, og);
}

int zc_venc_flushpage(zc_venc *e, ogg_page *og)
{
    return ogg_stream_flush(&e->os, og);
}
