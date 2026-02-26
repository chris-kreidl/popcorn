# Popcorn

A programming language inspired by TypeScript, implemented as a tree-walk interpreter in Zig.

File extension: `.pop`

## Building

Requires [Zig 0.15.2](https://ziglang.org/).

```sh
zig build
```

## Usage

Run a file:
```sh
./zig-out/bin/popcorn examples/hello.pop
```

Launch the REPL:
```sh
./zig-out/bin/popcorn
```

## Language Overview

### Variables

```
var x: int = 5;
const name: string = "Popcorn";
var flag = true;  // type annotation is optional
```

`const` variables cannot be reassigned.

### Types

`int`, `float`, `string`, `bool`, `null`

No implicit coercion between types.

### Operators

| Category   | Operators                    |
|------------|------------------------------|
| Arithmetic | `+` `-` `*` `/` `%`         |
| Comparison | `==` `!=` `<` `>` `<=` `>=` |
| Logical    | `&&` `||` `!`                |
| String     | `+` (concatenation)          |

### Control Flow

```
if x > 0 {
    print("positive");
} else {
    print("non-positive");
}

var i: int = 0;
while i < 10 {
    print(i);
    i = i + 1;
}
```

### Functions

```
fn add(a: int, b: int): int {
    return a + b;
}

print(add(3, 4));
```

Functions are first-class values with closures and support recursion.

### Print

`print()` is a built-in statement for output:

```
print("Hello, world!");
print(42);
```

### Comments

```
// single-line comments
```

## Example

```
// Fibonacci sequence
fn fibonacci(n: int): int {
    if n <= 1 {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

var i: int = 0;
while i < 10 {
    print(fibonacci(i));
    i = i + 1;
}
```

Output: `0 1 1 2 3 5 8 13 21 34`
