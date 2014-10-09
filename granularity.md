% Working draft for granularity control in PASL
% Deepsea project
% 19 August 2014

Introduction
============

As we begin work on this project, I propose that we document
our progress in documents like this one.
Any non-trivial designs should be prototyped and described first
in such a document and only then implemented in executable code.
None of the design that I am giving you now is set in stone.
In fact, far from it!
Please propose improvements as we go along.
You are welcome to make changes to this document and submit
them to me.
This design is going to be an iterative process.

The source format of this document might be new to you: it's a
*markdown* document.
The [markdown format](http://standardmarkdown.com/) is a
simple but powerful format that is described in precise detail
by a formal spec.
I am experimenting with using markdown because I like that
it's easy to read in raw text and can be converted to one
of many different formats by an awesome tool called
[pandoc](http://johnmacfarlane.net/pandoc/).
If you want to generate a `pdf` that looks like the one I'm sending you,
you can install pandoc and run the following command:

        pandoc granularity.md -s -S --biblio main.bib \
        --csl chicago-author-date.csl --highlight-style haddock \
        -o granularity.pdf

***Outline.***
The second section of this draft covers preliminaries and the third
lays out the design of our granularity control in PASL.
The fourth section is not yet completed but will eventually cover
our approach to parallel loops of various kinds.
The fifth section proposes next steps for the students to take
in the project.

Preliminaries
=============

This section describes a few parts of PASL that we are going to
use to build a higher level of abstraction for our
granularity-control prototype.

Workers
-------

In PASL, the *worker* abstraction represents the interface between the
parallel computations of the client and the processors in the system.
In particular, each worker is a process that corresponds to one PASL
thread running on one processor (at a given time).
More concretely, a worker is represented by a `pthread` that is running
an instance of the PASL scheduler.
During initialization, PASL spawns between $1$ and $P$ workers,
depending on how many worker threads are requested at the command
line (usually by the `-proc` command-line argument).

Just as `pthread`s have thread-local storage, workers have worker-local
storage.
For reasons that are beyond the scope of this prototype, the interface
that we use for worker-local storage is a little different from the
interface used by `pthread`s.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <class Item>
class perworker {
private:
  ...
public:
  Item& mine();
  ...
};
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

***Example.***
We can allocate and initialize and modify worker-local storage
of an integer as follows.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
perworker<int> x;
x.mine() = 0;
x.mine()++;
std::cout << mine() << std::endl;  // prints "1"
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Details of how perworker storage is implemented in PASL
can be found in `pasl/parutil/perworker.hpp`.

Binary fork join parallelism
----------------------------

The PASL runtime exports a number of primitive operations
that enable us to spawn lightweight parallel threads.
All of the operations of PASL are defined by the `prim` module and, for
the purposes of our prototype, their implementations are opaque to us.
In this context, spawning a lightweight parallel thread means
adding the thread to the work pool of the PASL scheduler.
For the moment we consider only binary fork join among the various
flavors of parallel primitives among the various flavors of parallel
primitives.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
namespace prim {
  ...
  template <class Body_fct1, class Body_fct2>
  void fork2(const Body_fct1& f1, const Body_fct2& f2);
  ...
  // later, add other primops here
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Semantics ###

The semantics of binary fork join is as follows: on a given call
`fork2(f1, f2)` both parallel branches, namely `f1()` and `f2()`,
are guaranteed to return before the `fork2` routine
returns.
Either zero, one, or both branches can be executed by the calling
worker.
If a given branch is not run by the calling worker, then the
branch is migrated to another worker by the PASL scheduler.
Note that, although our semantics is general in this regard,
PASL's work-stealing scheduler guarantees that the left branch is
always executed by the same worker that calls `fork2`; moreover,
the right branch is either migrated or not, but often it is
not.

### Scheduling overheads ###

A central issue for granularity control is the cost imposed by the
creation, destruction, and inter-worker migration of parallel
threads.
It is this cost that we wish to amortize by applying our
granularity-control techniques.
Thanks to the fact that the number of threads that are migrated
by PASL's work-stealing scheduler is negligible, we can focus
our attention to the overheads imposed in the case where both
parallel branches are executed by the same worker, namely
the thread creation and destruction costs.
In Section 7 of our Oracle Scheduling paper [^1], we analyzed
the cost of the binary fork join
operation in the Manticore implementation of Standard ML
and described the method we used to collect the measurements.
We do not currently have precise measurements to account for
the same cost in PASL, and neither do we have such measurements
for Cilk Plus.
Once we begin our empirical evaluation, we need to replicate
the study from our original paper for PASL and Cilk Plus on
our test machines.

Details of how fork join is implemented in PASL can be found
in `pasl/sched/native.hpp`.

Dynamic binding
---------------

If the concept of dynamic scope is unfamiliar, refer
to the wikipedia article before continuing [^2].
Our implementation of dynamic binding consists of the following
module.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <class Item>
class dynidentifier {
private:
  Item bk;
public:
  Item& back() {
    return bk;
  }
  template <class Block_fct>
  void block(Item x, const Block_fct& f) {
    Item tmp = bk;
    bk = x;
    f();
    bk = tmp;
  }
};
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Let *ident* be a dynamically scoped identifier.

- The call *ident*`.back()` returns a reference to the current binding
of the identifier `ident`.
- The call *ident*`.block(x, f)` creates a binding whose lifetime is
the same as the execution time of the call that it makes to `f()`
(a.k.a. the *block*).

### Example ###

Our example program prints `0 1 2 1 0`.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
dynidentifier<int> ident;
ident.back() = 0;
std::cout << ident.back() << " ";
ident.block(1, [&] {
  std::cout << ident.back() << " ";
  ident.block(2, [&] {
    std::cout << ident.back() << " ";
  });
  std::cout << ident.back() << " ";
});
std::cout << ident.back() << std::endl;
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Cycle counter
-------------

Our prediction-based granularity controller relies on a
fast, high-resolution timer mechanism because the prediction
involves collecting run-times of regions of code regularly
as the program runs.
Typically, modern processors provide instructions, such as
the `rdtsc` of x86, that offer efficient access to the
cycle counter.
In our prototype, we refer the following generic interface
provided by PASL.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
using ticks_type = ... // platform specific

ticks_type now ();  // returns current time

double since(ticks_type start);  // returns time elapsed since start
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Details of how these functions are implemented can be found
in `pasl/sequtil/ticks.hpp`

Granularity control
===================

The core of our approach consists of a few basic components.

- a few modes of execution that determine when a given region of code
is to be parallelized or sequentialized
- a binary fork-join function that is enhanced to enforce granularity control
- a number of granularity controllers
- a construct to specify regions of code that are to be managed by
specified granularity controllers

***Fib with forced granularity control.***
Let us consider the first in our running series of examples,
in which we apply our granularity control technique to the
naive recursive fibonacci function.
At this point, it is not important to understand every detail
of this code, but rather to get an intuitive feel for where we are going
in this section.

Our two simplest granularity controllers are
*force parallel* and *force sequential*.
The former forces the program to parallelize whenever
possible and the latter to sequentialize.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
class control_by_force_parallel   { };
class control_by_force_sequential { };
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Our fib function below can be configured in just one
or two ways:

1. parallelized by assigning to `cfib0` the type
`control_by_force_parallel`
2. sequentialized by assigning to `cfib0` the type
`control_by_force_sequential`

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
control_by_force_parallel cfib0;
// control_by_force_sequential cfib0;

// constructor functions for granularity-controlled regions
template <class Par_body_fct>
void cstmt(control_by_force_paralllel&, const Par_body_fct& f);
template <class Seq_body_fct>
void cstmt(control_by_force_sequential&, const Seq_body_fct& f);

long pfib0(long n) {
  if (n < 2)
    return n;
  long a,b;
  cstmt(cfib0, [&] { // granularity-controlled region
  // granularity-control enhanced binary fork join
  fork2([&] { a = pfib0(n-1); },
        [&] { b = pfib0(n-2); }); });
  return a + b;
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

In this section, we present the interface and semantics of
our granularity-control mechanisms in detail.
In the process, we develop a number of increasingly smarter
granularity controllers and show that we can apply the smarter granularity
controllers to our fib example by making a few minor
changes.

Execution modes
---------------

An *execution mode* is a directive that specifies the conditions
under which a worker can spawn parallel threads.
The `Force_parallel` and `Parallel` directives enable and
`Force_sequential` and `Sequential` prevent spawning of
parallel threads.
There is a subtle difference between the `Force`'d
modes and their counterparts that we still need to describe.
But for now, we postpone the precise specification,
until after we introduce a few more key concepts
of our scheme.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
using execmode_type = enum {
  Force_parallel,
  Force_sequential,
  Sequential,
  Parallel
};
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Execution-mode state ###

We use a global identifier to specify the execution modes of
the workers.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
perworker<dynidentifier<execmode_type>> execmode;
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The execution mode of the calling worker can be accessed by a call
to `my_execmode()`, which is given below.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
execmode_type my_execmode() {
  return execmode.mine().back();
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Initially, all cores are assigned the execmode `Parallel`.

Granularity-control-enhanced binary fork-join
---------------------------------------------

The implementation of our enhanced binary fork join routine is mostly
straightforward.
However, observe that we have a complication in the parallel branch
of our conditional.
That is, we have to create a block scope for each of our parallel
branches.
Can you explain why these two fresh block scopes are required?

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <class Body_fct1, class Body_fct2>
void fork2(const Body_fct1& f1, const Body_fct2& f2) {
  execmode_type m = my_execmode();
  if (     m == Sequential
       ||  m == Force_sequential ) {
    f1();  // sequentialize branches
    f2();
  } else { // parallel spawn enabled
    prim::fork2([&] { execmode.mine().block(m, f1); },
                [&] { execmode.mine().block(m, f2); });
  }
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Granularity controllers
-----------------------

We use the term *granularity controller* to refer to the
program logic that controls whether a given function call (or,
more generally, a given region of code) has permission to spawn
parallel threads.
In our C++ implementation, the regions of code for which
the controller makes its decisions are C++ statements.

A *granularity-controlled statement* (a.k.a. `cstmt`)
is a special kind of C++ statement that is assigned a
specified granularity controller.
It should be clear that, just like C++ statements, our
`cstmt`s can nest arbitrarily in client code.
As such, dynamic instances of statements can nest
arbitrarily at run time.
To make sense of such dynamic nesting, we define a
relation between the `execmode` of any two parent and
child `cstmt`s.
What this relation tells us is how the parent and child
are going to integrate their granularity-control decisions.
For now, let us simply state the signature of this relation
as the following C++ function and leave its definition for
later.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
// p is execmode of parent cstmt; c of child
execmode_type execmode_combine(execmode_type p, execmode_type c);
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We can now consider the run-time behavior of an arbitrary `cstmt`
named *s*.
The basic routine is the following:

1. Using the granularity controller of *s*, compute the `execmode`
*c* that is to be used for the execution of *s*.
2. Compute the `execmode` *e* to use for *s* by applying our
relation to
3. Bind `e` and in a fresh block and proceed to execute the body
of the `cstmt`.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
// to be called after step 1 computes c
template <class Body_fct>
void cstmt_base(execmode_type c, const Body_fct& body_fct) {
  execmode_type p = my_execmode();
  execmode_type e = execmode_combine(p, c); // step 2
  execmode.mine().block(e, body_fct);       // step 3
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Let us now assign precise semantics to our `execmode`s by
considering the dynamic behavior of an arbitrary `cstmt`
*s*, its parent *t*, along with their corresponding
`execmode`s *c* and *p*.

- If *c* `= Force_parallel`, then the execution of the body of *s*
  is parallelized.
- If *c* `= Force_sequential`, then the action is to similar
  the above, except that the body of *s* is
  sequentialized.
- If *c* `= Parallel`, then
    1. If *p* `= Sequential`, the execution of the body of *s* is
    sequentialized.
    2. Otherwise, the execution of the body of *s* is
    parallelized.
- If *c* `= Sequential`, then the execution of the body of *s*
  is sequentialized.

Check that this semantics is implemented by the definition
below.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
execmode_type execmode_combine(execmode_type p, execmode_type c) {
  // child gives priority to Force'd execmodes
  if (c == Force_parallel || c == Force_sequential)
    return c;
  // child gives priority to execmode of parent when parent is Sequential
  if (p == Sequential) {
    #ifdef LOGGING_ENABLED
    if (c == Parallel) // report bogus predictions
      log_granularity_control_mismatch();
    #endif
    return Sequential;
  }
  // otherwise, child execmode takes priority
  return c;
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Trivial granularity controllers: force parallel and sequential
--------------------------------------------------------------

The implementation of our force-parallel controller simply
creates a block scope in which the `execmode` is bound to
`Force_parallel`.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <class Par_body_fct>
void cstmt(control_by_force_parallel&, const Par_body_fct& par_body_fct) {
  // step 1
  execmode_type e = Force_parallel;
  cstmt_base(e, par_body_fct);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The sequential case is similar.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <class Seq_body_fct>
void cstmt(control_by_force_sequential&, const Par_body_fct& seq_body_fct) {
  // step 1
  execmode_type e = Force_sequential;
  cstmt_base(e, seq_body_fct);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Our purpose for `Force_parallel` and `Force_sequential`
is to provide tools for performance tuning and debugging.
We still need to explore the merit of having the `Force`'d
modes by considering more examples.

Cutoff-based granularity controller
-----------------------------------

A slightly more sophisticated granularity-control technique
involves the use of a client-supplied *cutoff function*,
which is a function of zero parameters that returns `true` to
select sequential execution and `false` to select parallel.

***Fib with cutoff-based granularity control.***
Returning to our running example, we see that we apply
our cutoff-based controller by:

1. changing the type of `cfib` to `control_by_cutoff_without_reporting`
2. passing our cutoff function in the second argument of `cstmt`

Our cutoff-based controller ensures that any call
`pfib1(n)` is sequentialized if the value of `n`
is less than or equal the threshold value of `fib_cutoff`.
Otherwise, the call may or may not be parallelized, depending
on whether or not the context of the call is parallel or
sequential.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
// cutoff-based controller definition
class control_by_cutoff_without_reporting { };

long fib_cutoff; // to be set by command-line argument

control_by_cutoff_without_reporting cfib; // change 1

// cstmt function to use for cutoff-based controller
template <class Cutoff_fct, class Par_body_fct>
void cstmt(control_by_cutoff_without_reporting&,
           const Cutoff_fct& cutoff_fct,
           const Par_body_fct& par_body_fct);

long pfib1(long n) {
  if (n < 2)
    return n;
  long a,b;
  // change 2
  cstmt(cfib, [&] { return n <= fib_cutoff; }, [&] {
  fork2([&] { a = pfib1(n-1); },
        [&] { b = pfib1(n-2); }); });
  return a + b;
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

***Remark.***
We actually have two variants of control by cutoff: one with
and one without reporting.
Because the distinction between the two variants it not relevant
yet for our purposes, we consider only the simpler of the two for now.

Our implementation of the cutoff-based controller uses a slightly
more general form that we used in our example.
In specific, the `cstmt` takes as fourth argument an alternative
sequentialized body function that is called when the cutoff
chooses sequential execution.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <
  class Cutoff_fct,
  class Par_body_fct,
  class Seq_body_fct
>
void cstmt(control_by_cutoff_without_reporting&,
           const Cutoff_fct& cutoff_fct,
           const Par_body_fct& par_body_fct,
           const Seq_body_fct& seq_body_fct) {
  execmode_type c = (cutoff_fct()) ? Sequential : Parallel;
  if (c == Sequential)
    cstmt_base(Sequential, seq_body_fct);
  else
    cstmt_base(Parallel, par_body_fct);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We get the `cstmt` form that we used in our example by using
the derived form below.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <class Cutoff_fct, class Par_body_fct>
void cstmt(control_by_cutoff_without_reporting& contr,
           const Cutoff_fct& cutoff_fct,
           const Par_body_fct& par_body_fct) {
  cstmt(contr, cutoff_fct, par_body_fct, par_body_fct);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Alternative client-supplied sequential body ###

This alternative form offers the possibility to use faster
sequentialized code at the expense of

1. defining a purely sequential fib
2. passing as the fourth argument of`cstmt` an alternative
sequentialized body function

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
// purely sequential fib
long fib(long n) {
  if (n < 2)
    return n;
  long a,b;
  a = fib(n-1);
  b = fib(n-2);
  return a+b;
}

long pfib2(long n) {
  if (n < 2)
    return n;
  long a,b;
  cstmt(cfib, [&] { return n <= fib_cutoff; }, [&] {
  fork2([&] { a = pfib2(n-1); },
        [&] { b = pfib2(n-2); }); },
  [&] { a = fib(n-1);  // alternative sequentialized body
        b = fib(n-2); });
  return a + b;
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Prediction-based granularity controller
---------------------------------------

The weaknesses of the cutoff-based approach are well known
and studied in our Oracle Scheduling paper and in the Lazy
Binary Splitting paper of Tzannes et al. [^3]
Briefly, the cutoff-based approach has two major weaknesses:

***Platform dependence.*** The range of good cutoffs for any given 
region of code depends on not only on the algorithm but also on the
various costs involved in scheduling parallel threads.
To complicate matters, the scheduling costs may vary significantly
from scheduler to scheduler and from chip architecture to
chip architecture.
The programmer should not have to consider such low-level
details, if possible.

***Context dependence.*** In any non-trivial parallel program, parallel
computations typically nest in complex ways, leading to 
*nested parallelism*.
The cutoff-based technique fails at nested parallelism because
the cutoff itself is not sensitive to its context.
This limitation encourages programmers to break abstraction boundaries
in their code to make separate regions of code aware of each
others' cutoff decisions.
Programmers should not have to make such changes to get
efficient parallel programs.

Our prediction-based granularity controller is our way of addressing
these issues.
Many of the concepts that we are using here can be found in Section
5 of our Oracle Scheduling paper [^1].

### Complexity measure ###

A *complexity measure* is an integer value represents some
algorithmic cost, such as the number of comparisons performed by
a sort function or number of arithmetic operations performed
by a matrix multiplication function.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
using cmeasure_type = long;
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

We reserve two values to represent special cases:

- The tiny complexity represents a cost that is negligible.
- The the undefined complexity measure represents a case where
no measure is provided.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
constexpr cmeasure_type tiny      = -1l;
constexpr cmeasure_type undefined = -2l;
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Complexity function ###

The complexity function that we are going to use
for our running fib example is $c(n) = \phi^n$.
This function represents the average-case complexity
of our fib function.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
cmeasure_type phi_to_pow(long n) {
  constexpr double phi = 1.61803399;
  return (cmeasure_type)pow(phi, (double)n);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Control-by-prediction class ###

This controller class is a little more interesting than
the other controller classes we have seen so far because
each instance of `control_by_prediction` has a unique
identity.
The identity is owing to the *constant estimator data
structure* that is represented by the one private
member of the class.

The `name` parameter of this class is used by the
constant estimator data structure to
report statistics on a per-estimator basis
and to remember profiling data across multiple runs of
the program.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
class control_by_prediction {
private:
  constant_estimator estimator;
public:
  control_by_prediction(std::string name = "")
  : estimator(name) { }
  constant_estimator& get_estimator() {
    return estimator;
  }
};
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

***Fib with prediction-based granularity control.***
Before we get into the details of the constant estimator
data structure, let us return to our running example.
The code looks a lot like the code from our cutoff-based
example, except that `cfib` has the type `control_by_prediction`
and the second argument being passed to `cstmt` is now
our complexity function.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
control_by_prediction cfib("fib");

template <class Complexity_measure_fct, class Par_body_fct>
void cstmt(control_by_prediction& contr,
           const Complexity_measure_fct& complexity_measure_fct,
           const Par_body_fct& par_body_fct);

// parallel fib with complexity function
static
long pfib3(long n) {
  if (n < 2)
    return n;
  long a,b;
  cstmt(cfib, [&] { return phi_to_pow(n); }, [&] {
  fork2([&] { a = pfib3(n-1); },
        [&] { b = pfib3(n-2); }); });
  return a + b;
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Somehow, the machinery behind this controller has to use
the information at hand, namely the result of the complexity
function and the profiling data that it captures during
sequentialzed runs, to make effective granularity-control
decisions.
How does this happen?
The remainder of this section addresses this quesiton.

### Constant-estimator data structure ###

Internally, the constant estimator data structure maintains
a mapping from abstract costs as expressed by cost
functions to machine costs as expressed by time,
in the case of our implementation, by the type
`cost_type` which is in units of microseconds.
The internal mapping is updated by making a *report*
and is queried by maing a *prediction*.

- *Report:* the call `report(`*m*, *elapsed*`)` adds the data point
represented by *m* and *elapsed* to the running estimate. The value *m* is
the abstract cost reported by the application of the complexity
function. The value *elapsed* is the elapsed time in microseconds
that it took to run the corresponding computation.
- *Predict:* the call `predict(`*m*`)` computes and returns a prediction of
the cost in microseconds of an operation with abstract cost *m*.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
using cost_type = double;

class constant_estimator {
private:
  // ...
  static perworker<int> unique_estimator_id;
  std::string name;
  static std::string uniqify(std::string name) {
    int x = unique_estimator_id.mine()++;
    return name + "<" + std::to_string(x) + ">";
  }
public:
  constant_estimator(std::string name) {
    name = uniqify(name);
  }
  std::string get_name() const {
    return name;
  }
  void report(cmeasure_type m, cost_type elapsed);
  cost_type predict(cmeasure_type m);
};
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Measured runs ###

In order get data points to report to the constant estimator,
we do measured runs.
A *measured run* is a call `cstmt_base(`*m*, *seq_body_fct*, *estimator*`)`
that performs the following steps:

1. run the sequentialized computation *seq_body_fct*`()`
2. report to the constant estimator *estimator* the data point represented
by the pair (*m*, *elapsed*), where
    - *m* represents the complexity measure associated with *seq_body_fct*`()`
    - *elapsed* represents the running time of *seq_body_fct*`()`

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
// measured run of a sequentialized computation
template <class Seq_body_fct>
void cstmt_base(cmeasure_type m,
                const Seq_body_fct& seq_body_fct,
                constant_estimator& estimator) {
  cost_type start = now();
  cstmt_base(Sequential, seq_body_fct);
  cost_type elapsed = since(start);
  estimator.report(m, elapsed);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Controller logic ###

The controller logic uses one platform-specific parameter called
`kappa`.
This parameter represents an upper bound on the thread
creation and destruction cost and corresponds to the parameter
$\kappa$ that we use in our Oracle Scheduling paper.
Generally, we set our `kappa` to be tens of microseconds.
However, we do not yet have accurate measurements for the
relevant `kappa` values for our test machines.
In the future, to save repeating the same experiment on every
machine we use, we should implement a generic program that estimates
`kappa` automatically for us for any given machine.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
double kappa; // in microseconds
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The logic of the controller is straightforward.
If the amount of computation is deemed to be smaller than the
`kappa` threshold, then the computation is sequentialized.
Otherwise, the computation is potentially parallelized
(depending, as usual, on the context of the call).
Note that the sequentialized computation is always performed
as a measured run.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <
  class Complexity_measure_fct,
  class Par_body_fct,
  class Seq_body_fct
>
void cstmt(control_by_prediction& contr,
           const Complexity_measure_fct& complexity_measure_fct,
           const Par_body_fct& par_body_fct,
           const Seq_body_fct& seq_body_fct) {
  constant_estimator& estimator = contr.get_estimator();
  cmeasure_type m = complexity_measure_fct();
  execmode_type c;
  if (m == tiny)
    c = Sequential;
  else if (m == undefined)
    c = Parallel;
  else
    c = (estimator.predict(m) <= kappa) ? Sequential : Parallel;
  if (c == Sequential)
    cstmt_base(m, seq_body_fct, estimator);
  else
    cstmt_base(Parallel, par_body_fct);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The example code we presented earlier in this section actually
uses a special form of the `cstmt` that requires only the
parallel body, and not the sequentialized alternative body.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ {.cpp}
template <
  class Complexity_measure_fct,
  class Par_body_fct
>
void cstmt(control_by_prediction& contr,
           const Complexity_measure_fct& complexity_measure_fct,
           const Par_body_fct& par_body_fct) {
  cstmt(contr, complexity_measure_fct, par_body_fct, par_body_fct);
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Challenge problems
------------------

***Adequate complexity functions***
In our Oracle Scheduling paper, we mention a few conditions
that client-supplied complexity functions must honor in
order for our prediction scheme to function effectively.
One condition that we mention is, for example, the requirement
that the complexity functions themselves should take
constant time and should be very fast.
After all, the longer to prediction takes, the less the advantage
we get from our granularity controller!
But another condition that we do not mention is that the complexity
function should represent the *average-case complexity* and,
moreover, that the average- and worst-case complexity should
be the same.

1. Can you think of a few algorithms where average and worst
case complexity are not the same?
2. Can you think of what might go wrong in our granularity-control
scheme in cases where average and worst-case complexity do not match?

***Cutoff logic***
Observe that, in Figure 3 of our paper [^1], we define the
cutoff logic somewhat differently.
That is, when we consider a binary fork join operation,
we sequentialize only if both parallel branches are predicted
to be smaller than $\kappa$.

1. Can you explain why we defined it as such in the paper?
2. Can you explain how we defined it differently in this prototype?
3. Can you either think of a good way to implement our `fork2` in the same way
that its implemented in our paper or argue why it cannot be done?

A good solution to Problem 3 is not yet known to us.

Discussion
----------

Our dynamic scoping discipline gives us the flexibility to
experiment with the behavior of nests of `cstmt`s in a
number of ways.
For example, suppose we have `cstmt`s *s* and *t*,
such that *t* appears in the body
of *s*. Furthermore, suppose that in a particular instance
the granularity controller of *t* chooses serial execution,
but the granularity controller of *s* chooses parallel.
What should happen in this situation?
Should *s* be allowed to spawn parallel threads or should
it be serialized?
Does this situation indicate a mistake or miscalibration in
the granularity controller?
Perhaps there is no single answer that is useful in every
situation.
On the one hand, in production code, the programmer may want
to silently serialize *s*.
On the other hand, while tuning the code, the programmer
may be interested to log the mismatch between *t* and *s*.

Efficient parallel loops
========================

Work for the near future

Summary
=======

The following proposes a sequence of first steps for Vitaly and
Anna to take to kick start their projects.

1. *Work on the C++ prototype.*
Owing to time limitations, I did not yet update the C++ source code
that is accompanying this draft to match with the current design.
The students can familiarize themselves with the draft by
either updating the accompanying code to match the design in
the current draft, or, if preferred, by
starting a fresh C++ source file.
2. *Add at least one new example to the C++source file.*
In particular,
a good candidate is the parallel mergesort that Vitaly and Anna
implemented some time ago.
3. *Integrate the prototype with the PASL library.*
Much of this
work should be straightforward but perhaps require a few afternoons
worth of time. Once we complete this step, however, we can start
to run experiments.
4. *Run initial experiments.*
We need to first get accurate measurements of the thread creation
and destruction costs on our machines, both for PASL and
Cilk.
5. *Analyze the accuracy of the predictions made by our prediction-based
granularity controller.*
We want to understand better the limitations of our prediction method
by experimenting with many applications with many different algorithms.

Finally, we need to start thinking about how to divide this project into
two mostly independent subprojects so that, at the end, Vitaly
and Anna can easily identify the own independent contributions.

References
==========

[^1]: [@Oracle_scheduling_11]
[^2]: http://en.wikipedia.org/wiki/Scope_(computer_science)
[^3]: [@Lazy_binary_splitting_10]
