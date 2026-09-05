#!/bin/sh
# 15秒動画をコマンドだけで組み立てる手順（2026-09-05 実行済み）
# 前提: python3 + pillow, ffmpeg 7.0.2（imageio-ffmpeg 同梱版で可）
#   pip install pillow imageio-ffmpeg
#   FF=$(python3 -c "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())")
set -e
FF=${FF:-ffmpeg}

# 1) 場面の静止画を4枚つくる
python3 scenes.py

# 2) 1枚ずつ、ゆっくり流れる4.05秒のクリップにする
for i in 0 1 2 3; do
  if [ $((i%2)) -eq 0 ]; then
    X="(in_w-1080)*(t/4.05)"; Y="(in_h-1920)*(t/4.05)"
  else
    X="(in_w-1080)*(1-t/4.05)"; Y="(in_h-1920)*(1-t/4.05)"
  fi
  "$FF" -y -loop 1 -t 4.05 -i s$i.png \
    -vf "scale=1188:2112,crop=1080:1920:x='$X':y='$Y',format=yuv420p" \
    -c:v libx264 -preset veryfast -crf 20 -r 30 c$i.mp4
done

# 3) 重ねてつなぎ、字幕を焼き込み、音を敷いて15秒に切る
"$FF" -y \
 -i c0.mp4 -i c1.mp4 -i c2.mp4 -i c3.mp4 \
 -f lavfi -t 15 -i "sine=frequency=220:sample_rate=48000" \
 -f lavfi -t 15 -i "sine=frequency=330:sample_rate=48000" \
 -f lavfi -t 15 -i "sine=frequency=440:sample_rate=48000" \
 -filter_complex "\
[0:v][1:v]xfade=transition=fade:duration=0.35:offset=3.70[v01];\
[v01][2:v]xfade=transition=fade:duration=0.35:offset=7.40[v02];\
[v02][3:v]xfade=transition=fade:duration=0.35:offset=11.10[vx];\
[vx]trim=0:15,setpts=PTS-STARTPTS[vt];\
[vt]subtitles=subs.srt:force_style='FontName=IPAGothic,FontSize=9.5,PrimaryColour=&H00FFFFFF,OutlineColour=&HC0000000,BorderStyle=1,Outline=0.6,Shadow=0,Alignment=2,MarginV=44,MarginL=16,MarginR=16'[vo];\
[4:a]volume=0.05,tremolo=f=0.4:d=0.6[a1];\
[5:a]volume=0.035[a2];\
[6:a]volume=0.02,tremolo=f=0.25:d=0.7[a3];\
[a1][a2][a3]amix=inputs=3:duration=shortest,afade=t=in:st=0:d=1.2,afade=t=out:st=13.3:d=1.7,alimiter=limit=0.4[ao]" \
 -map "[vo]" -map "[ao]" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 \
 -c:a aac -b:a 128k -movflags +faststart -t 15 \
 "AI秘書の15秒_自動生成テスト_2026-09-05.mp4"

# 字幕の文字サイズは PlayResY=288 を基準に 6.67倍へ拡大される。
# FontSize=9.5 が実寸およそ63px、MarginV=44 が実寸およそ293px にあたる。
