# Dynamic Fee Hook using Directional Fee

### **A template for writing Uniswap v4 Hooks 🦄**

Made using [`Use this Template`](https://github.com/uniswapfoundation/v4-template/generate)

---

## Set up

_requires [foundry](https://book.getfoundry.sh)_

```
forge install
forge test
```

### Directional Fee

- A uniswap hook to adjust fee based on change in pool price at t and t-1 block.
- Original formula proposed by Nezlobin,

```
δ=cΔ, for some c>0.
```

δ represents change in fees, increase the fee for buys and lower the fee for sales δ for price change Δ.

With this implementation and simulation environment with limited dataset, we saw some improvements varying where fees collected by LPs were increased by 0.2 to 0.05% than normal pool.

The simulation in following [results](./sims/output.png)

- [Set 1](./sims/s3)
- [Set 2](./sims/s5)

However, we can iterate on the above idea and improve several aspects of it to make more profitable for LPs and fair for swappers.

- One such improvement can be the implementation of anti fragile fees, inspired by Anti Fragility coined by Nassim Taleb.

- Value of `c` can also be made dynamic but further research is required to determine which factors should be considered in determining a new value of `c` that will change the fees.
