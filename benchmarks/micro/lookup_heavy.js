// lookup_heavy.js
// Variable-lookup-heavy benchmark.

const a = 1;
const b = 2;
const c = 3;
const d = 4;
const e = 5;
const f = 6;
const g = 7;
const h = 8;

let sum = 0;
for (let i = 0; i < 2000000; i++) {
  sum = sum + a + b + c + d + e + f + g + h;
}
console.log(sum);
