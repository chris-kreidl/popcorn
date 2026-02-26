// call_heavy.js
// Function-call-heavy benchmark.

function mix(x) {
  return (x * 3 + 1) % 97;
}

let sum = 0;
for (let i = 0; i < 800000; i++) {
  sum += mix(i);
}
console.log(sum);
