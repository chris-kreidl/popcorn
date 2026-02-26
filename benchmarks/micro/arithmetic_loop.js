// arithmetic_loop.js
// Arithmetic-heavy loop without I/O in the hot path.

let acc = 0;
for (let i = 0; i < 2000000; i++) {
  acc = acc + (i % 7) * 3 - (i % 5);
}
console.log(acc);
