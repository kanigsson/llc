--  Huffman.Encoding.Length_Limited_Coding
------------------------------------------
--  Legal licensing note:

--  Copyright (c) 2016 .. 2019 Gautier de Montmollin (maintainer of the Ada version)
--  SWITZERLAND
--
--  The copyright holder is only the maintainer of the Ada version;
--  authors of the C code and those of the algorithm are cited below.

--  Permission is hereby granted, free of charge, to any person obtaining a copy
--  of this software and associated documentation files (the "Software"), to deal
--  in the Software without restriction, including without limitation the rights
--  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--  copies of the Software, and to permit persons to whom the Software is
--  furnished to do so, subject to the following conditions:

--  The above copyright notice and this permission notice shall be included in
--  all copies or substantial portions of the Software.

--  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
--  THE SOFTWARE.

--  NB: this is the MIT License, as found 21-Aug-2016 on the site
--  http://www.opensource.org/licenses/mit-license.php

--  Author: lode.vandevenne [*] gmail [*] com (Lode Vandevenne)
--  Author: jyrki.alakuijala [*] gmail [*] com (Jyrki Alakuijala)

--  Bounded package merge algorithm, based on the paper
--    "A Fast and Space-Economical Algorithm for Length-Limited Coding
--    Jyrki Katajainen, Alistair Moffat, Andrew Turpin".

--  Translated by G. de Montmollin to Ada from katajainen.c (Zopfli project), 7-Feb-2016
--
--  Main technical differences to katajainen.c:
--    - pointers are not used, array indices instead
--    - all structures are allocated on stack
--    - sub-programs are nested, then unneeded parameters are removed

--  Annotations and modifications for the purpose of SPARK analysis by Johannes Kanig 
--  TODO list some main differences here


procedure LLC
  (frequencies : in     Count_Array;
   bit_lengths :    out Length_Array)
is
  subtype Index_Type_Invalid is Count_Type range 0 .. Count_Type (2 * max_bits * (max_bits + 1));
  subtype Index_Type is Index_Type_Invalid range 0 .. Index_Type_Invalid'Last - 1;

  null_index : constant Index_Type := Index_Type'Last;

  type Leaf_Node is record
    weight : Count_Type;
    symbol : Alphabet;
  end record;

  type Leaf_array is array (Index_Type range <>) of Leaf_Node;

  too_many_symbols_for_length_limit : exception;

  function Count_Symbols_Ghost (A : Alphabet) return Index_Type with Ghost
  is ((if frequencies (A) > 0 then 1 else 0) + 
      (if A = Alphabet'First then 0 else Count_Symbols_Ghost (A'Pred)));

  function Count_Symbols return Index_Type
  with Post => 
    Count_Symbols'Result = Count_Symbols_Ghost (Alphabet'Last)
    and then Count_Symbols'Result >= 0
    and then Count_Symbols'Result <= 2 ** max_bits
  is
    num_symbols : Count_Type := 0;
  begin
    for a in Alphabet loop
      if frequencies (a) > 0 then
        num_symbols := num_symbols + 1;
      end if;
      pragma Loop_Invariant (num_symbols <= Alphabet'Pos (a));
    end loop;
    --  Check special cases and error conditions.
    if num_symbols > 2 ** max_bits then
      raise too_many_symbols_for_length_limit;  --  Error, too few max_bits to represent symbols.
    end if;
    return num_symbols;
  end Count_Symbols;

  num_symbols : constant Index_Type := Count_Symbols;  --  Amount of symbols with frequency > 0.

  subtype Leaves_Index_Type_Invalid is Index_Type range 0 .. num_symbols;
  subtype Leaves_Index_Type is Leaves_Index_Type_Invalid range 0 .. Leaves_Index_Type_Invalid'Last - 1;
  leaves : Leaf_array (Leaves_Index_Type);

  --  Nodes forming chains.
  type Node is record
    weight : Count_Type;
    count  : Leaves_Index_Type_Invalid;                --  Number of leaves before this chain.
    tail   : Index_Type := null_index;  --  Previous node(s) of this chain, or null_index if none.
    in_use : Boolean    := False;       --  Tracking for garbage collection.
  end record;


  --  Memory pool for nodes.
  pool : array (Index_Type) of Node;
  pool_next : Index_Type_Invalid := pool'First;

  type Index_pair is array (Index_Type'(0) .. 1) of Index_Type;
  subtype List_Index_Type is Index_Type range 0 .. Index_Type (max_bits - 1);
  lists : array (List_Index_Type) of Index_pair;


  num_Boundary_PM_runs : Count_Type;

  zero_length_but_nonzero_frequency : exception;
  nonzero_length_but_zero_frequency : exception;
  length_exceeds_length_limit       : exception;
  buggy_sorting                     : exception;

  procedure Init_Node (weight : Count_Type; count : Leaves_Index_Type_Invalid; tail, node_idx : Index_Type) with Pre => True is
  begin
    pool (node_idx).weight := weight;
    pool (node_idx).count  := count;
    pool (node_idx).tail   := tail;
    pool (node_idx).in_use := True;
  end Init_Node;

  --  Finds a free location in the memory pool. Performs garbage collection if needed.
  --  If use_lists = True, used to mark in-use nodes during garbage collection.

  --  Copy of Get_Free_Node where we hardcode use_lists = False
  function Init_Get_Free_Node return Index_Type with Side_Effects is
  begin
    loop
      if pool_next > pool'Last then
        --  Garbage collection.
        for i in pool'Range loop
          pool (i).in_use := False;
        end loop;
        pool_next := pool'First;
      end if;
      exit when not pool (pool_next).in_use;  -- Found one.
      pool_next := pool_next + 1;
    end loop;
    pool_next := pool_next + 1;
    return pool_next - 1;
  end Init_Get_Free_Node;

  --  Copy of Get_Free_Node where we hardcode use_lists = True
  function Get_Free_Node return Index_Type with Side_Effects is
    node_idx : Index_Type;
  begin
    loop
      if pool_next > pool'Last then
        --  Garbage collection.
        for i in pool'Range loop
          pool (i).in_use := False;
        end loop;
        for i in 0 .. Index_Type (max_bits * 2 - 1) loop
          node_idx := lists (i / 2)(i mod 2);
          while node_idx /= null_index loop
            pool (node_idx).in_use := True;
            node_idx := pool (node_idx).tail;
          end loop;
        end loop;
        pool_next := pool'First;
      end if;
      exit when not pool (pool_next).in_use;  -- Found one.
      pool_next := pool_next + 1;
    end loop;
    pool_next := pool_next + 1;
    return pool_next - 1;
  end Get_Free_Node;

  --  Performs a Boundary Package-Merge step. Puts a new chain in the given list. The
  --  new chain is, depending on the weights, a leaf or a combination of two chains
  --  from the previous list.
  --  index: The index of the list in which a new chain or leaf is required.
  --  final: Whether this is the last time this function is called. If it is then it
  --  is no more needed to recursively call self.

  procedure Boundary_PM (index : List_Index_Type; final : Boolean)
    with Subprogram_Variant => (Decreases => index)
  is
    newchain  : Index_Type;
    oldchain  : Index_Type;
    lastcount : constant Leaves_Index_Type_Invalid := pool (lists (index)(1)).count;  --  Count of last chain of list.
    sum : Count_Type;
  begin
    if index = 0 and lastcount >= num_symbols then
      return;
    end if;
    newchain := Get_Free_Node;
    oldchain := lists (index)(1);
    --  These are set up before the recursive calls below, so that there is a list
    --  pointing to the new node, to let the garbage collection know it's in use.
    lists (index) := (oldchain, newchain);

    if index = 0 then
      --  New leaf node in list 0.
      Init_Node (leaves (lastcount).weight, lastcount + 1, null_index, newchain);
    else
      sum := pool (lists (index - 1)(0)).weight + pool (lists (index - 1)(1)).weight;
      if lastcount < num_symbols and then sum > leaves (lastcount).weight then
        --  New leaf inserted in list, so count is incremented.
        Init_Node (leaves (lastcount).weight, lastcount + 1, pool (oldchain).tail, newchain);
      else
        Init_Node (sum, lastcount, lists (index - 1)(1), newchain);
        if not final then
          --  Two lookahead chains of previous list used up, create new ones.
          Boundary_PM (index - 1, False);
          Boundary_PM (index - 1, False);
        end if;
      end if;
    end if;
  end Boundary_PM;

  --  Initializes each list with as lookahead chains the two leaves with lowest weights.

  procedure Init_Lists with Pre => num_symbols >= 2 is
    node0 : Index_Type;
    node1 : Index_Type;
  begin
    node0 := Init_Get_Free_Node;
    node1 := Init_Get_Free_Node;
    Init_Node (leaves (0).weight, 1, null_index, node0);
    Init_Node (leaves (1).weight, 2, null_index, node1);
    lists := (others => (node0, node1));
  end Init_Lists;

  --  Converts result of boundary package-merge to the bit_lengths. The result in the
  --  last chain of the last list contains the amount of active leaves in each list.
  --  chain: Chain to extract the bit length from (last chain from last list).

  procedure Extract_Bit_Lengths (chain : Index_Type) with Pre => num_symbols >= 2 is
    node_idx : Index_Type := chain;
  begin
    while node_idx /= null_index loop
      for i in 0 .. pool (node_idx).count - 1 loop
        bit_lengths (leaves (i).symbol) := bit_lengths (leaves (i).symbol) + 1;
      end loop;
      node_idx := pool (node_idx).tail;
    end loop;
  end Extract_Bit_Lengths;

  procedure Quick_sort (a : in out Leaf_array)
    with Pre => 0 <= A'Length and then A'Length <= Index_Type'Last
  is
    n : constant Index_Type := a'Length;
    i, j : Index_Type;
    t : Leaf_Node;
    middle : constant Index_Type := n / 2;
  begin
    if n < 2 then
      return;
    end if;
    declare
      p : constant Leaf_Node := a (a'first + middle);
    begin
      i := 0;
      j := n - 1;
      loop
        pragma Loop_Invariant
          (i in 0 .. n - 1
           and then j in 0 .. n - 1
           and then (for all k in 0 .. i - 1 => a (a'first + k).weight <= p.weight)
           and then (for all k in j + 1 .. n - 1 => p.weight <= a (a'first + k).weight)
           and then (for some k in 0 .. n - 1 => p.weight = a (a'first + k).weight));

        while i < n - 1 and then  a (a'first + i).weight < p.weight loop
          pragma Loop_Invariant
            (i in 0 .. n - 1
             and then (for all k in 0 .. i => a (a'first + k).weight <= p.weight)
            );
          i := i + 1;
        end loop;
        while j > 0 and then p.weight < a (a'First + j).weight loop
          pragma Loop_Invariant
            (j in 0 .. n - 1
             and then (for all k in j .. n - 1 => p.weight <= a (a'first + k).weight)
            );
          j := j - 1;
        end loop;
        exit when i >= j;
        t := a (i + a'First);
        a (i + a'First) := a (j + a'First);
        a (j + a'First) := t;
        if i < n - 1 and j > 0 then
          i := i + 1;
          j := j - 1;
        end if;
      end loop;
      Quick_sort (a (a'First .. a'First + i - 1));
      Quick_sort (a (a'First + i .. a'Last));
    end;
  end Quick_sort;

begin
  bit_lengths := (others => 0);
  --  Count used symbols and place them in the leaves.

 for a in Alphabet loop
    if frequencies (a) > 0 then
      leaves (num_symbols) := (frequencies (a), a);
      num_symbols := num_symbols + 1;
    end if;
  end loop;

  if num_symbols = 0 then
    return;  --  No symbols at all. OK.
  end if;
  if num_symbols = 1 then
    bit_lengths (leaves (0).symbol) := 1;
    return;  --  Only one symbol, give it bit length 1, not 0. OK.
  end if;
  --  Sort the leaves from lightest to heaviest.
  Quick_sort (leaves (0 .. num_symbols - 1));
  Init_Lists;
  --  In the last list, 2 * num_symbols - 2 active chains need to be created. Two
  --  are already created in the initialization. Each Boundary_PM run creates one.
  num_Boundary_PM_runs := 2 * num_symbols - 4;
  for i in 1 .. num_Boundary_PM_runs loop
    Boundary_PM (Index_Type (max_bits - 1), i = num_Boundary_PM_runs);
  end loop;
  Extract_Bit_Lengths (lists (Index_Type (max_bits - 1))(1));
end LLC;
