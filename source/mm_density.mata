*! version 1.0.0  06aug2020  Ben Jann
version 11.2

// class & struct
local MAIN   mm_density
local SETUP  _`MAIN'_setup
local Setup  struct `SETUP' scalar
// real
local RS     real scalar
local RR     real rowvector
local RC     real colvector
local RV     real vector
// counters
local Int    real scalar
local IntC   real colvector
// string
local SS     string scalar
// boolean
local Bool   real scalar
local TRUE   1
local FALSE  0
// transmorphic
local T      transmorphic
local TS     transmorphic scalar
// pointers
local Pf     pointer(function) scalar
local PC     pointer(real colvector) scalar

mata:

// ---------------------------------------------------------------------------
// class definition
// ---------------------------------------------------------------------------

struct `SETUP' {
    // data
    `PC'    X             // pointer to X
    `PC'    w             // pointer to w
    `RS'    nobs          // number of obs/sum of weights
    `Bool'  pw            // weights are sampling weights
    `Bool'  sorted        // whether data is sorted

    // kernel
    `SS'    kernel        // name of kernel
    `Int'   adapt         // stages of adaptive estimator
    `Pf'    k             // kernel function
    `Pf'    K             // kernel integral function
    `RS'    kh            // canonical bandwidth of kernel

    // bandwidth selection
    `RS'    h0            // user provided bandwidth
    `SS'    bwmethod      // bandwidth estimation method
    `RS'    bwadjust      // bandwidth adjustment factor
    `Int'   dpi           // number of DPI stages; default is 2

    // support/boundary correction
    `RS'    lb            // lower boundary (missing if unbounded)
    `RS'    ub            // upper boundary (missing if unbounded)
    `SS'    bcmethod      // boundary correction method
    `Int'   bc            // 0=none, 1=renorm, 2=reflect, 3=linear correction
    `Bool'  rd            // relative data

    // other settings
    `Int'   n             // size of approximation grid
}

class `MAIN' {
    // settings
    public:
        void    data()        // set data
        `T'     kernel()      // kernel settings/retrieve kernel name
        void    bw()          // bandwidth settings
        void    support()     // support/boundary correction
        `T'     n()           // set/retrieve size of approximation grid
    private:
        void    new()         // initialize class with default settings
        void    clear()       // clear all results
        `Setup' setup         // settings
        `RC'    k(), K()      // kernel functions
        `RC'    kbc(), krn(), // boundary-correction kernels
                krf(), klc()
        `RS'    h0()          // retrieve user bandwidth
        void    checksuprt()  // check whether data is within support
    public:
        `RC'    X(), w()      // retrieve X and w
        `RS'    nobs()        // retrieve N (sum of weights)
        `Bool'  sorted()      // retrieve sorted flag
        `Int'   adapt()       // retrieve stages of adaptive estimator
        `RS'    kh()          // retrieve canonical bandwidth of kernel
        `SS'    bwmethod()    // retrieve bw seletion method
        `RS'    bwadjust()    // retrieve bw adjustment factor
        `Int'   dpi()         // retrieve dpi level
        `Bool'  pw()          // retrieve pweighte flag
        `RS'    lb(), ub()    // retrieve lower and upper bounds of support
        `SS'    bcmethod()    // retrieve boundary-correction method
        `Bool'  rd()          // retrieve relative data flag

    // results
    public:
        `RC'    d()          // estimate/retrieve d
        `RS'    h()          // estimate/retrieve h
        `RC'    at()         // retrieve at
        `RC'    l()          // retrieve l
        `RC'    D()          // estimate/retrieve D
        `RC'    AT()         // set/retrieve AT
        `RC'    W()          // set/retrieve W
        `RC'    L()          // retrieve L
    private:
        `RC'    d            // density estimate
        `RS'    h            // bandwidth
        `RC'    at           // evaluation grid
        `RC'    l            // local bandwidth factors (at observation level)
        `RC'    D            // full grid approximation estimate
        `RC'    AT           // approximation grid
        `RC'    W            // grid counts
        `RC'    L            // local bandwidth factors
        
    // internal functions
    private:
        `RS'    h_sjpi(), h_isj(), h_dpi(), h_si(), h_ov(), h_no(), h_rd(), 
                df(), __h_sjpi()
        `Int'   _h_sjpi()
        `RC'    dd()
        void    dexact()
        `RC'    _dexact()
        void    dapprox(), _dapprox(), _dapprox_fft(), _dapprox_fft_rf(),
                _dapprox_std()
        `RC'    lbwf()
        `RC'    ipolate()
        `RC'    grid()
        `RS'    scale()
}

// ---------------------------------------------------------------------------
// settings
// ---------------------------------------------------------------------------

void `MAIN'::new()
{
    kernel("")
    bw("")
    support()
    n(1024)
}

void `MAIN'::clear()
{
    d  = J(0,1,.)
    h  = .
    at = J(0,1,.)
    l  = J(0,1,.)
    D  = J(0,1,.)
    AT = J(0,1,.)
    W  = J(0,1,.)
    L  = J(0,1,.)
}

// D.data() -------------------------------------------------------------------

void `MAIN'::data(`RC' X, | `RC' w, `Bool' pw, `Bool' sorted)
{   // -sorted- indicates that
    //     X is sorted and non-missing
    //     w is non-missing and non-negative
    if (args()<2) w = 1
    if (args()<3) pw  = `FALSE'
    if (args()<4) sorted = `FALSE'
    if (pw!=`FALSE' & pw!=`TRUE') _error(3300)
    if (sorted!=`FALSE' & sorted!=`TRUE') _error(3300)
    if (!sorted) {
        if (missing(X) | missing(w)) _error(3351)
        if (any(w:<0)) {
            display("{err}{it:w} must not be negative")
            _error(3300)
        }
    }
    if (sorted==`FALSE') checksuprt(X, lb(), ub())
    setup.nobs   = mm_nobs(X, w)
    setup.X      = &X
    setup.w      = &w
    setup.pw     = pw
    setup.sorted = sorted
    clear()
}

`RC' `MAIN'::X()
{
    if (setup.X==NULL) return(J(0,1,.))
    return(*setup.X)
}

`RC' `MAIN'::w()
{
    if (setup.w==NULL) return(1)
    return(*setup.w)
}

`RS' `MAIN'::nobs() return(setup.nobs)

`Bool' `MAIN'::pw() return(setup.pw)

`Bool' `MAIN'::sorted() return(setup.sorted)

// D.kernel() -----------------------------------------------------------------

`T' `MAIN'::kernel(| `SS' kernel, `Int' adapt)
{
    // get
    if (args()==0) {
        return(setup.kernel)
    }
    // set
    setup.kernel = _mm_unabkern(strlower(strtrim(kernel)))  // default is "epan2"
    setup.k      = _mm_findkern(setup.kernel)
    setup.K      = _mm_findkint(setup.kernel)
    setup.kh     = (*_mm_findkdel0(setup.kernel))()
    if (args()<2) adapt = 0
    if (adapt<0)  _error(3300)
    if (adapt>=.) _error(3300)
    setup.adapt = trunc(adapt)
    clear()
}

`RS' `MAIN'::kh() return(setup.kh)

`Int' `MAIN'::adapt() return(setup.adapt)

`RC' `MAIN'::k(`RC' X) {
    return((*setup.k)(X))
}

`RC' `MAIN'::K(`RS' l, | `RC' X)
{
    if (args()==1) return((*setup.K)(l))
    return((*setup.K)(l, X))
}

`RC' `MAIN'::kbc(`RC' X, `RC' x, `RC' h)
{
    if (setup.bc==0) return(k((x:-X):/h))
    if (setup.bc==1) return(krn(X, x, h))
    if (setup.bc==2) return(krf(X, x, h))
    if (setup.bc==3) return(klc(X, x, h))
    // not reached
}

`RC' `MAIN'::krn(`RC' X, `RC' x, `RC' h)
{   // renormalization kernel
    `RC' k
    
    k = k((x:-X):/h)
    if (lb()<. & ub()<.) k = k :/ (K(1, (ub():-x):/h) - K(1, (lb():-x):/h))
    else if (lb()<.)     k = k :/  K(1, (x:-lb()):/h)
    else if (ub()<.)     k = k :/  K(1, (ub():-x):/h)
    return(k)
}

`RC' `MAIN'::krf(`RC' X, `RC' x, `RC' h)
{   // reflection kernel
    `RC' k
    
    k = k((x:-X):/h)
    if (lb()<.) k = k + k((x:-2*lb():+X):/h)
    if (ub()<.) k = k + k((x:-2*ub():+X):/h)
    return(k)
}

`RC' `MAIN'::klc(`RC' X, `RC' x, `RC' h)
{   // linear correction kernel
    `RC' k, z, a0, a1, a2, l
    
    z = (x:-X):/h
    k = k(z)
    if (ub()<.) {
        l = (ub():-x):/h
        a0 =  K(1, l)
        a1 = -K(3, l)
        a2 =  K(4, l)
        if (lb()<.) {
            l  = (lb():-x):/h
            a0 = a0 :- K(1, l)
            a1 = a1 :+ K(3, l)
            a2 = a2 :- K(4, l)
        }
    }
    else if (lb()<.) {
        l  = (x:-lb()):/h
        a0 = K(1, l)
        a1 = K(3, l)
        a2 = K(4, l)
    }
    else return(k)
    return((a2 :- a1:*z):/(a0:*a2-a1:^2) :* k)
}

// D.bw() -------------------------------------------------------------------

void `MAIN'::bw(| `TS' arg, `RS' adj, `Int' dpi)
{
    // syntax 1: bw(#)
    if (args()==1) {
        if (!isstring(arg)) {
            if (arg<=0) _error(3300)
            if (arg>=.) _error(3300)
            setup.h0 = arg
            return
        }
    }
    // syntax 2: bw(method, adjust, dpi)
    if (args()<2) adj = 1
    if (args()<3) dpi = 2
    if (adj<=0) _error(3300)
    if (adj>=.) _error(3300)
    if (dpi<0)  _error(3300)
    if (dpi>=.) _error(3300)
    setup.bwmethod = mm_strexpand(strlower(strtrim(arg)),
        ("silverman", "normalscale", "oversmoothed", "sjpi", "dpi", "isj"),
        "sjpi") // default is "sjpi"
    setup.h0       = .
    setup.bwadjust = adj
    setup.dpi      = trunc(dpi)
    clear()
}

`RS' `MAIN'::h0() return(setup.h0)

`SS' `MAIN'::bwmethod() return(setup.bwmethod)

`RS' `MAIN'::bwadjust() return(setup.bwadjust)

`Int' `MAIN'::dpi() return(setup.dpi)

// D.support() ----------------------------------------------------------------

void `MAIN'::support(| `RV' minmax, `SS' method, `Bool' rd)
{
    `RS' lb, ub
    
    if (args()<3) rd     = `FALSE'
    if (length(minmax)>2) _error(3200)
    if (rd!=`FALSE' & rd!=`TRUE') _error(3300)
    if (length(minmax))   lb = minmax[1]
    else                  lb = .
    if (length(minmax)>1) ub = minmax[2]
    else                  ub = .
    if (lb<. & ub<.) {
        if (lb>=ub) _error(3300)
    }
    if (rd) {
        if (lb <  0)  _error(3300)
        if (lb >= .)  lb = 0
        if (ub >  1)  _error(3300)
        if (ub >= .)  ub = 1
        if (lb > ub)  _error(3300)
    }
    if (sorted()==`FALSE') checksuprt(X(), lb, ub)
    setup.bcmethod = mm_strexpand(strlower(strtrim(stritrim(method))),
        ("renormalization", "reflection", "linear correction"),
        "renormalization") // default is "renormalization"
    setup.lb = lb
    setup.ub = ub
    setup.rd = rd
    if (setup.lb>=. & setup.ub>=.)                  setup.bc = 0
    else if (setup.bcmethod=="renormalization")     setup.bc = 1
    else if (setup.bcmethod=="reflection")          setup.bc = 2
    else if (setup.bcmethod=="linear correction")   setup.bc = 3
    else _error(3498) // cannot be reached
    clear()
}

`RS' `MAIN'::lb() return(setup.lb)

`RS' `MAIN'::ub() return(setup.ub)

`SS' `MAIN'::bcmethod() return(setup.bcmethod)

`Bool' `MAIN'::rd() return(setup.rd)

void `MAIN'::checksuprt(`RC' X, `RS' lb, `RS' ub)
{
    if (rows(X)==0) return // no data
    if (lb<.) {
        if (min(X)<lb) {
            display("{err}{it:X} contains values out of support")
            _error(3300)
        }
    }
    if (ub<.) {
        if (max(X)>ub) {
            display("{err}{it:X} contains values out of support")
            _error(3300)
        }
    }
}

// D.n() ----------------------------------------------------------------------

`T' `MAIN'::n(| `Int' arg)
{
    // get
    if (args()==0) return(setup.n)
    // set
    if (arg<1) _error(3300)
    if (arg>.) _error(3300)
    setup.n = trunc(arg)
    clear()
}

// ---------------------------------------------------------------------------
// bandwidth selection
// ---------------------------------------------------------------------------

`RS' `MAIN'::h() {
    if (h<.) return(h)
    // user bandwidth
    if (h0()<.) { 
        h = h0()
        return(h)
    }
    // data-driven bandwidth selection
    if (bwmethod()=="sjpi") {
        h = h_sjpi()
        if (h>=.) {
            display("{txt}(SJPI estimation failed; using oversmoothed bandwidth)")
            h = h_ov()
        }
    }
    else if (bwmethod()=="isj") {
        h = h_isj()
        if (h>=.) {
            display("{txt}(ISJ estimation failed; using oversmoothed bandwidth)")
            h = h_ov()
        }
    }
    else if (bwmethod()=="dpi")          h = h_dpi()
    else if (bwmethod()=="silverman")    h = h_si()
    else if (bwmethod()=="oversmoothed") h = h_ov()
    else if (bwmethod()=="normalscale")  h = h_no()
    else _error(3498) // cannot be reached
    // correction for pweights
    if (pw() & rows(w())!=1) {
        h = h * (sum(w():^2)/(nobs()))^.2
    }
    // final adjustments
    h = h * kh() * bwadjust()
    return(h)
}

`RS' `MAIN'::h_rd(`RS' s) // relative data correction factor
{
    if (rd()) return((1 + 1/(2 * sqrt(pi()) * s))^.2)
    return(1)
}

// Sheather-Jones solve-the-equation plug-in selection rule -------------------

`RS' `MAIN'::h_sjpi()
{
    `RS'  n, s, l, hos, hmin, ax, bx, sda, tdb, tdc, alpha, beta, h
    `Int' rc
    `RC'  AT, W
    pragma unset h
    
    s = scale(1)                     // standard deviation
    l = min((s, scale(2)))           // minimum of SD and normalized IQR
    AT = grid(n())                   // evaluation grid
    W  = mm_fastlinbin(X(), w(), AT) // grid counts
    if (pw()) {                      // pweights: normalize grid counts
        n = rows(X())
        W = W * (n / nobs())
    }
    else n = nobs()
    sda = df(AT, W, n, 1.241 * l * n^(-1/7), 2)
    tdb = df(AT, W, n, 1.230 * l * n^(-1/9), 3)
    alpha = 1.357 * (sda/tdb)^(1/7)
    if (rd()) {
        tdc = df(AT, W, n, 1.304 * l * n^(-1/5), 1)
        beta = 1.414 * (sda/tdc)^(1/3)
    }
    hmin = (AT[n()]-AT[1])/(n()-1) / 2 * mm_kdel0_gaussian() / mm_kdel0_rectangle()
    hos  = s * (243/(35*n))^.2 * mm_kdel0_gaussian() * h_rd(s) // h oversmoothed
    bx = hos
    ax = max((hmin, bx/2))
    rc = _h_sjpi(h, ax, bx, AT, W, n, alpha, beta)
    if (rc==2) { // move down
        bx = ax
        while (1) {
            if (bx<=hmin) break // cannot go below hmin
            ax = max((hmin, bx/2))
            rc = _h_sjpi(h, ax, bx, AT, W, n, alpha, beta)
            if (rc==2) bx = ax // continue moving down
            else break // this also stops if there is a change in 
                      //  direction (rc==3) (in this case: h = current bx)
        }
    }
    else if (rc==3) { // move up
        ax = bx; bx = ax*1.5
        while (1) {
            rc = _h_sjpi(h, ax, bx, AT, W, n, alpha, beta)
            if (rc==3) {; ax = bx; bx = ax*1.5; } // continue moving up
            else break // this also stops if there is a change in 
                       //  direction (rc==2) (in this case: h = current ax)
        }
    }
    if (h<=hmin) { // solution is smaller than hmin
        ax = hos; bx = ax*1.5
        rc = _h_sjpi(h, ax, bx, AT, W, n, alpha, beta)
        if (rc==2) return(.) // moving up does not help
        if (rc==3) { // continue moving up
            ax = bx; bx = ax*1.5
            while (1) {
                rc = _h_sjpi(h, ax, bx, AT, W, n, alpha, beta)
                if (rc==3) {; ax = bx; bx = ax*1.5; } // continue moving up
                else break // this also stops if there is a change in 
                           //  direction (rc==2) (in this case: h = current ax)
            }
        }
    }
    return(h * (n/nobs())^.2 / mm_kdel0_gaussian())
}

`Int' `MAIN'::_h_sjpi(`RS' x, `RS' ax, `RS' bx, 
    `RC' AT, `RC' W, `RS' n, `RS' alpha, `RS' beta)
{   // root finder for SJPI; adapted from mm_root()
    `Int' maxit, itr
    `RS'  tol, tol_act
    `RS'  a, b, c, fa, fb, fc, prev_step, p, q, new_step, t1, cb, t2

    tol   = ax * 0.1
    maxit = 100
    a = ax; b = bx
    fa = __h_sjpi(a, AT, W, n, alpha, beta)
    fb = __h_sjpi(b, AT, W, n, alpha, beta)
    c = a; fc = fa
    if ( fa==. ) return(0)
    if ( (fa > 0 & fb > 0) | (fa < 0 & fb < 0) ) {
        if ( abs(fa) < abs(fb) ) {
            x = a; return(2)
        }
        x = b; return(3)
    }
    for (itr=1; itr<=maxit; itr++) {
        if ( fb==. ) return(0)
        prev_step = b-a
        if ( abs(fc) < abs(fb) ) {
            a = b;  b = c;  c = a; fa = fb; fb = fc; fc = fa
        }
        tol_act = 2*epsilon(b) + tol/2
        new_step = (c-b)/2
        if ( abs(new_step) <= tol_act | fb == 0 ) {
             x = b
             return(0)
        }
        if ( abs(prev_step) >= tol_act & abs(fa) > abs(fb) ) {
            cb = c-b
            if ( a==c ) {
                t1 = fb/fa
                p = cb*t1
                q = 1.0 - t1
            }
            else {
                q = fa/fc;  t1 = fb/fc;  t2 = fb/fa
                p = t2 * ( cb*q*(q-t1) - (b-a)*(t1-1.0) )
                q = (q-1.0) * (t1-1.0) * (t2-1.0)
            }
            if ( p>0 ) q = -q
            else      p = -p
            if ( p < (0.75*cb*q-abs(tol_act*q)/2) & p < abs(prev_step*q/2) )
                new_step = p/q
        }
        if ( abs(new_step) < tol_act ) {
            if ( new_step > 0 ) new_step = tol_act
            else                new_step = -tol_act
        }
        a = b;  fa = fb
        b = b + new_step; fb = __h_sjpi(b, AT, W, n, alpha, beta)
        if ( (fb > 0 & fc > 0) | (fb < 0 & fc < 0) ) {
            c = a;  fc = fa
        }
    }
    x = b
    return(1)
}

`RS' `MAIN'::__h_sjpi(`RS' h, `RC' AT, `RC' W, `RS' n, `RS' alpha, `RS' beta)
{
    `RS' d
    
    d = mm_kint_gaussian(2)
    if (rd()) d = d * (1 + df(AT, W, n, beta * h^(5/3), 0))
    return((d / (n * df(AT, W, n, alpha * h^(5/7), 2)))^0.2 - h)
}

`RS' `MAIN'::df(`RC' AT, `RC' W, `RS' n, `RS' h, `Int' d)
{
    return( (-1)^d * sum(W :* dd(AT, W, n, h, d)) / n )
}

`RC' `MAIN'::dd(`RC' AT, `RC' W, `RS' n, `RS' h, `Int' d)
{    // d'th density derivative using gaussian kernel
    `Int' M, L, i, first, last
    `RS'  a, b
    `RC'  kappam, arg, hmold0, hmold1, hmnew, w
    
    // compute kappam
    M = rows(AT)
    a = AT[1]; b = AT[M]
    L = (M-1) * (1 + lb()<. + ub()<.)
    L = max( (min( (floor((4 + 2*d) * h * (M-1)/(b-a)), L) ), 1) )
    arg = (0::L) * (b-a) / (h*(M-1))
    kappam = normalden(arg)
    hmold0 = 1; hmold1 = arg; hmnew  = 1
    for (i=2; i<=2*d; i++) { // compute mth degree Hermite polynomial
        hmnew  = arg :* hmold1 :- (i-1) * hmold0
        hmold0 = hmold1; hmold1 = hmnew
    }
    kappam = hmnew :* kappam
    
    // unbounded estimator
    if (lb()>=. & lb()>=.) {
        return( convolve((kappam[L+1::1] \ kappam[|2 \ L+1|]), 
            W)[|L+1 \ L+M|] / (n*h^(2*d+1)) )
    }
    
    // reflection estimator
    w = W
    if (lb()<.) {
        first = M
        w = W[M::2] \ w
        w[first] = 2 * w[first]
    }
    else first = 1
    last = first + (M-1)
    if (ub()<.) {
        w = w \ W[M-1::1]
        w[last] = 2 * w[last]
    }
    return( convolve((kappam[L+1::1] \ kappam[|2 \ L+1|]), 
        w)[|L+first \ L+last|] / (n*h^(2*d+1)) )
}

// "improved" SJPI (diffusion method) -----------------------------------------

`RS' `MAIN'::h_isj()
{
    `Int' n
    `RS'  N, h, hmin
    `RC'  AT, W, a
    
    // step 1: bin data on regular grid
    n = 2^ceil(ln(n())/ln(2))        // round up to next power of 2
    AT = grid(n)                     // generate grid
    W  = mm_fastlinbin(X(), w(), AT) / nobs() // compute relative frequencies
    if (pw()) N = rows(X())          // obtain sample size
    else      N = nobs()
    // step 2: obtain discrete cosine transform of binned data
    a = Re( (1 \ 2 * exp(1i * (1::n-1) * pi() / (2*n)))
         :* fft(W[mm_seq(1,n-1,2)] \ W[mm_seq(n,2,2)]) )
    // step 3: compute bandwidth
    h = sqrt(mm_minim(&_mm_density_h_isj_fxpnt(), 0, .1, 10^-22, N, 
        (1::n-1):^2, (a[2::n] / 2):^2)) * (AT[n]-AT[1])
    // return result
    hmin = (AT[n]-AT[1])/(n-1) / 2 * mm_kdel0_gaussian() / mm_kdel0_rectangle()
    if (h<hmin) return(.)  // bandwidth too small (collapsed to zero)
    h = h * (N/nobs())^.2 / mm_kdel0_gaussian() // rescale
    if (rd()) h = h * h_rd(scale(0)) // relative data correction
    return(h)
}

`RS' _mm_density_h_isj_fxpnt(`RS' h, `RS' N, `RC' I, `RC' a2)
{
    `Int' l, s
    `RS'  K0, c
    `RC'  f, t
    
    l = 7
    f = 2 * pi()^(2*l) * sum(I:^l :* a2 :* exp(-I * pi()^2 * h))
    for (s=l-1; s>=2; s--) {
        K0 = mm_prod(mm_seq(1, 2*s-1, 2)) / sqrt(2*pi())
        c  = (1 + (1/2)^(s + 1/2)) / 3
        t  = (2 * c * K0/N/f):^(2/(3 + 2*s))
        f  = 2 * pi()^(2*s) * sum(I:^s :* a2 :* exp(-I * pi()^2 * t))
    }
    return(abs(h - (2 * N * sqrt(pi()) * f)^(-2/5)))
}

// Sheather-Jones direct plug-in selection rule -------------------------------

`RS' `MAIN'::h_dpi()
{
    `RS'  n, s, alpha, psi, psi0, alpha0
    `Int' i
    `RC'  AT, W
    
    s = scale(0)
    i = dpi()
    if (i==0) { // h normalscale
        psi = 3 / (8 * sqrt(pi()) * s^5)
        if (rd()) psi0 = 1 / (2 * sqrt(pi()) * s)
        else      psi0 = 0
    }
    else {
        AT = grid(n())                   // evaluation grid
        W  = mm_fastlinbin(X(), w(), AT) // grid counts
        if (pw()) {                      // pweights: normalize grid counts
            n = rows(X())
            W = W * (n / nobs())
        }
        else n = nobs()
        alpha = (2 * (sqrt(2) * s)^(3 + 2 * (i+1)) /
                ((1 + 2 * (i+1)) * n))^(1/(3 + 2 * (i+1)))
        if (rd()) alpha0 = (2 * (sqrt(2) * s)^(3 + 2 * (i-1)) /
                           ((1 + 2 * (i-1)) * n))^(1/(3 + 2 * (i-1)))
        for (; i; i--) {
            psi = df(AT, W, n, alpha, i+1)
            if (rd()) psi0 = df(AT, W, n, alpha0, i-1)
            else      psi0 = 0
            if (i>1) {
                alpha = ( factorial(i*2) / (2^i * factorial(i)) *
                          sqrt(2/pi()) / (psi*n) )^(1/(3 + 2*i))
                if (rd()) alpha0 = ( factorial((i-2)*2) / (2^(i-2) * 
                                   factorial(i-2)) * sqrt(2/pi()) / 
                                   (psi0*n) )^(1/(3 + 2*(i-2)))
            }
        }
    }
    return( ((1 + psi0) / (psi * nobs()))^.2 )
}

// optimal of Silverman selection rule ----------------------------------------

`RS' `MAIN'::h_si()
{
    `RS' s
    
    s = scale(0) 
    return(0.9/mm_kdel0_gaussian() * s / nobs()^.2 * h_rd(s))
}

// oversmoothed selection rule ------------------------------------------------

`RS' `MAIN'::h_ov()
{
    `RS' s
    
    s = scale(1) 
    return((243/35)^.2 * s / nobs()^.2 * h_rd(s))
}

// normal scale selection rule ------------------------------------------------

`RS' `MAIN'::h_no()
{
    `RS' s
    
    s = scale(0) 
    return((8*sqrt(pi())/3)^.2 * s / nobs()^.2 * h_rd(s))
}

// ---------------------------------------------------------------------------
// density estimation
// ---------------------------------------------------------------------------

`RC' `MAIN'::d(| `RV' o1, `RS' o2, `RS' o3, `RS' o4)
{
    // case 0: return existing result
    if (args()==0) return(d)
    // case 1: o1 contains grid
    if (args()<=2) {
        if (cols(o1)!=1)   at = o1'
        else               at = o1
        // case 1a: exact estimator
        if (args()==2 & o2) dexact()
        // case 1b: approximation estimator
        else d = ipolate(AT(), D(), at, mm_issorted(at))
        return(d)
    }
    // case 2: o1=n, o2=from, o3=to
    at = grid(o1, h(), o2, o3)
    // case 2a: exact estimator
    if (args()==4 & o4) dexact()
    // case 2b: approximation estimator
    else d = ipolate(AT(), D(), at, mm_issorted(at))
    return(d)
}

`RC' `MAIN'::at() return(at)

// exact estimator ------------------------------------------------------------

void `MAIN'::dexact()
{
    `Int'  n
    `IntC' p
    
    n = rows(at)
    if (setup.bc & n>0) {
        // check for evaluation points out of support and set density
        // to zero for these points
        if (lb()<. & ub()<.) p = select(1::n, at:>=lb() :& at:<=ub())
        else if (lb()<.)     p = select(1::n, at:>=lb())
        else if (ub()<.)     p = select(1::n, at:<=ub())
        if (length(p)!=n) {
            d = J(n,1,0)
            if (length(p)) d[p] = _dexact(X(), w(), h() :* l(), at[p])
            return
        }
    }
    d = _dexact(X(), w(), h() :* l(), at)
}

`RC' `MAIN'::_dexact(`RC' x, `RC' w, `RC' h, `RC' at)
{
    `Int' i
    `RC'  d
    
    i = rows(at)
    d = J(i,1,.)
    // using slightly different method depending on whether h and w are
    // scalar or not to save a bit of computer time, if possible
    if (rows(h)==1 & rows(w)==1) {
        for (;i;i--) d[i] = w/h * sum(kbc(x, at[i], h))
    }
    else if (rows(h)==1) {
        for (;i;i--) d[i] = sum(w :* kbc(x, at[i], h)) / h
    }
    else if (rows(w)==1) {
        for (;i;i--) d[i] = w * sum(kbc(x, at[i], h) :/ h)
    }
    else {
        for (;i;i--) d[i] = sum(w:/h :* kbc(x, at[i], h))
    }
    return(d / nobs())
}

`RC' `MAIN'::l()
{
    if (rows(l)) return(l)
    if (!adapt()) return(1)
    D = L = J(0,1,.)   // clear approximation estimator
    dapprox(adapt()-1) // compute preliminary approximation estimator
    l = lbwf(ipolate(AT, D, X(), sorted()), w())
    _dapprox()         // complete last step of approximate estimator (this is 
                       // not needed for the exact estimator, but it ensures
                       // that D() and L() will return correct results)
    return(l)
}

// binned approximation estimator ---------------------------------------------

`RC' `MAIN'::D()
{
    if (rows(D)) return(D)
    dapprox(adapt())
    return(D)
}

`RC' `MAIN'::AT()
{
    if (rows(AT)) return(AT)
    AT = grid(n(), h())
    return(AT)
}

`RC' `MAIN'::W()
{
    if (rows(W)) return(W)
    W = mm_fastlinbin(X(), w(), AT())
    return(W)
}

`RC' `MAIN'::L()
{
    if (rows(L)) return(L)
    if (!adapt()) return(1)
    dapprox(adapt())
    return(L)
}

void `MAIN'::dapprox(`Int' adapt)
{
    // create grid and compute grid counts if necessary
    if (rows(W)==0) (void) W()
    // obtain estimate
    _dapprox()
    // go to next stage of adaptive estimator
    if (adapt) dapprox(adapt-1)
}

void `MAIN'::_dapprox()
{
    `RC' h
    
    // obtain h
    h = h()
    if (rows(D)) {
        L = lbwf(D, W)
        h = h :* L
    }
    // FFT estimation if h is constant
    if (rows(h)==1) {
        if (setup.bc<=1)      _dapprox_fft(h)    // no bc or renormalization
        else if (setup.bc==2) _dapprox_fft_rf(h) // reflection
        else                  _dapprox_std(h)    // linear correction (no FFT)
    }
    // else use standard estimator
    else _dapprox_std(h)
}

void `MAIN'::_dapprox_fft(`RS' h)
{
    `Int' M, L
    `RS'  a, b, tau
    `RC'  kappa
    
    M = rows(AT)
    a = AT[1]; b = AT[M]
    L = M - 1
    // reduce number of evaluation points if possible
    if (kernel()!="gaussian") {
        if (kernel()=="cosine")            tau = .5
        else if (kernel()=="epanechnikov") tau = sqrt(5)
        else                               tau = 1
        L = max( (min( (floor(tau*h*(M-1)/(b-a)), L) ), 1) )
    }
    // compute kappa and obtain FFT
    kappa = k( (0::L) * (b-a) / (h*(M-1)) )
    D = convolve((kappa[L+1::1]\kappa[|2 \ L+1|]), W)[|L+1 \ L+M|] / (nobs()*h)
    if (setup.bc==0) return
    // renormalization boundary correction
    if (lb()<. & ub()<.) D = D :/ (K(1, (ub():-AT):/h) - K(1, (lb():-AT):/h))
    else if (lb()<.)     D = D :/  K(1, (AT:-lb()):/h)
    else if (ub()<.)     D = D :/  K(1, (ub():-AT):/h)
}

void `MAIN'::_dapprox_fft_rf(`RS' h)
{
    `Int' M, L, first, last
    `RS'  a, b, tau
    `RC'  kappa, w
    
    M = rows(AT)
    a = AT[1]; b = AT[M]
    L = (M-1) * (1 + (lb()<.) + (ub()<.))
    // reduce number of evaluation points if possible
    if (kernel()!="gaussian") {
        if (kernel()=="cosine")            tau = .5
        else if (kernel()=="epanechnikov") tau = sqrt(5)
        else                               tau = 1
        L = max( (min( (floor(tau*h*(M-1)/(b-a)), L) ), 1) )
    }
    // expand vector of grid counts
    w = W
    if (lb()<.) {
        first = M
        w = W[M::2] \ w
        w[first] = 2 * w[first]
    }
    else first = 1
    last = first + (M-1)
    if (ub()<.) {
        w = w \ W[M-1::1]
        w[last] = 2 * w[last]
    }
    // ompute kappa and obtain FFT
    kappa = k( (0::L) * (b-a) / (h*(M-1)) )
    D = convolve((kappa[L+1::1]\kappa[|2 \ L+1|]), w)[|L+first \ L+last|] / 
        (nobs()*h)
    if (setup.bc==0) return
}

void `MAIN'::_dapprox_std(`RC' h)
{
    `Int' n, i, a, b
    `RC'  r
    
    // no computational shortcut in case of gaussian kernel
    if (kernel()=="gaussian") {
        D = _dexact(AT, W, h, AT)
        return
    }
    // other kernels: restrict computation to relevant range of evaluation points
    n = n()
    r = h
    if (kernel()=="cosine")            r = r * .5
    else if (kernel()=="epanechnikov") r = r * sqrt(5)
    r = trunc(r * (n-1) / (AT[n]-AT[1])) :+ 1 // add 1 to prevent roundoff error
    D = J(n,1,0)
    if (rows(h)==1) {
        for (i=n;i;i--) {
            a = max((1, i-r))
            b = min((n, i+r))
            D[|a \ b|] = D[|a \ b|] + W[i] / h * kbc(AT[i], AT[|a \ b|], h)
        }
        D = D :/ nobs()
        return
    }
    for (i=n;i;i--) {
        a = max((1, i-r[i]))
        b = min((n, i+r[i]))
        D[|a \ b|] = D[|a \ b|] + W[i] / h[i] * kbc(AT[i], AT[|a \ b|], h[i])
    }
    D = D :/ nobs()
}

// ---------------------------------------------------------------------------
// helper functions
// ---------------------------------------------------------------------------

`RC' `MAIN'::grid(`Int' n, | `RS' h, `RS' from, `RS' to)
{
    `RS' tau
    `RR' range, minmax
    
    range = J(1,2,.)
    if (from<.)       range[1] = from
    else if (lb()<.)  range[1] = lb()
    if (to<.)         range[2] = to
    else if (ub()<.)  range[2] = ub()
    if (missing(range)) {
        minmax = minmax(X())
        if (h<.) {
            // if h is provided: extend grid such that density can go to
            // zero outside data range
            tau = h * (kernel()=="epanechnikov" ? sqrt(5) : 
                (kernel()=="cosine" ? .5 : (kernel()=="gaussian" ? 3 : 1)))
        }
        else {
            // if h is not provided: extend grid by 5% of data range
            tau = (minmax[2]-minmax[1]) / 20
        }
        if (range[1]>=.)  range[1] = minmax[1] - tau
        if (range[2]>=.)  range[2] = minmax[2] + tau
    }
    if (range[1]>range[2]) _error(3300)
    return(rangen(range[1], range[2], n))
}

`RS' `MAIN'::scale(`Int' type)
{   // type: 0 = min(sd,iqr), 1 = sd, 2 = iqr
    // iqr will be replaced by sd if 0
    `RS' iqr, sd
    
    if (type!=1) {
        if (sorted()) iqr = _mm_iqrange(X(), w()) / 1.349
        else          iqr =  mm_iqrange(X(), w()) / 1.349
    }
    if (type!=2 | iqr<=0) {
        sd = sqrt(variance(X(), w()))
        if (pw()) sd = sd * sqrt( (nobs()-1) / (nobs() - nobs()/rows(X())) )
    }
    if (type==1) return(sd)
    if (iqr<=0)  iqr = sd
    if (type==2) return(iqr)
    return(min((sd, iqr)))
}

`RC' `MAIN'::lbwf(`RC' d, `RC' w) // local bandwidth factors
{
    `RC' l
    
    l = sqrt( exp(mean(log(d), w)) :/ d)  // exp(...) -> geometric mean
    return(editmissing(l, 1))
}

`RC' `MAIN'::ipolate(`RC' AT, `RC' D, `RC' at, `Bool' sorted)
{
    `RC' d, p
    
    if (sorted) d = mm_fastipolate(AT, D, at)
    else {
        p = order(at, 1)
        d = mm_fastipolate(AT, D, at[p])
        d[p] = d
    }
    _editmissing(d, 0)  // set density outside of grid to 0
    return(d)
}

end
