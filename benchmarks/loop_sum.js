// loop_sum.js
// Integer loop and accumulation benchmark.

let sum = 0;
for (let i = 0; i < 5000000; i++) {
  sum += i;
}
console.log(sum);
