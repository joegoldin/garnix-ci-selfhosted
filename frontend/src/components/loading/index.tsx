"use client";
import React from "react";
import styles from "./styles.module.css";

/** A function to describe the animation easing for the leader. */
const leaderEasing = (x: number) => x * 1.4;

/** A function to describe the animation easing for the follower. */
const followerEasing = (x: number) => x * x * x;

/** How many frames the total animation should take */
const PERIOD = 110;

const WIDTH = 100;
const HEIGHT = 100;

type Point = [number, number];

const points: Array<Point> = [
  [50, 72],
  [50, 50],
  [96, 50],
  [96, 5],
  [4, 5],
  [4, 50],
  [4, 96],
  [96, 96],
  [96, 50],
  [50, 50],
  [50, 72],
];

const getPointIdxAndDelta = (n: number): { idx: number; delta: number } => {
  const x = Math.max(0, Math.min(1, n)) * (points.length - 1);
  const idx = Math.floor(x);
  const delta = x - idx;
  return { idx, delta };
};

const getPoint = ({ idx, delta }: { idx: number; delta: number }): Point => {
  if (idx >= points.length - 1) return points[points.length - 1]!;
  return lerp(delta, points[idx]!, points[idx + 1]!);
};

const lerp = (n: number, a: Point, b: Point): Point => {
  const inverse = 1 - n;
  return [inverse * a[0] + n * b[0], inverse * a[1] + n * b[1]];
};

const draw = (ctx: CanvasRenderingContext2D, timeInPeriod: number) => {
  ctx.fillStyle = "#f2f2f2";
  ctx.lineWidth = 5;
  ctx.lineCap = "round";
  ctx.fillRect(0, 0, WIDTH, HEIGHT);
  ctx.beginPath();
  ctx.strokeStyle = "#bebdc0";
  ctx.moveTo(...points[0]!);
  for (let i = 0; i < points.length; i++) {
    ctx.lineTo(...points[i]!);
  }
  ctx.stroke();
  const leader = getPointIdxAndDelta(leaderEasing(timeInPeriod));
  const follower = getPointIdxAndDelta(followerEasing(timeInPeriod));
  const leaderPoint = getPoint(leader);
  const followerPoint = getPoint(follower);
  ctx.beginPath();
  ctx.strokeStyle = "#221d28";
  ctx.moveTo(...followerPoint);
  for (let i = follower.idx + 1; i <= leader.idx; i++) {
    ctx.lineTo(...points[i]!);
  }
  ctx.lineTo(...leaderPoint);
  ctx.stroke();
};

export const Loading = ({ className }: { className?: string }) => {
  const ref = React.useRef<HTMLCanvasElement>(null);
  React.useEffect(() => {
    const ctx = ref.current?.getContext("2d");
    if (!ctx) return;
    let mounted = true;
    let time = 0;
    const frame = () => {
      if (!mounted) return;
      time = (time + 1) % PERIOD;
      draw(ctx, time / PERIOD);
      requestAnimationFrame(frame);
    };
    frame();
    return () => {
      mounted = false;
    };
  }, []);
  return (
    <div className={`${styles.container} ${className}`}>
      <canvas ref={ref} width={WIDTH} height={HEIGHT} />
    </div>
  );
};
