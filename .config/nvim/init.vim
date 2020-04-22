let mapleader="\<Space>"
let CACHE_PATH = system('VAR="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/"; mkdir -p "$VAR"; echo -n $VAR')

call plug#begin(CACHE_PATH)
call plug#end()

" Basic stuff
    set mouse=a
    set clipboard+=unnamedplus
    set tabstop=4 shiftwidth=4 expandtab
    set wildmode=longest,list,full
    set splitbelow splitright
    set showtabline=2

" No autocoments
    autocmd FileType * setlocal formatoptions-=cro

" Vimdiff colors
    highlight DiffAdd    cterm=BOLD ctermfg=NONE ctermbg=22
    highlight DiffDelete cterm=BOLD ctermfg=NONE ctermbg=52
    highlight DiffChange cterm=BOLD ctermfg=NONE ctermbg=23
    highlight DiffText   cterm=BOLD ctermfg=NONE ctermbg=23

" Configurations
    let netrw_banner = 0
    let netrw_winsize = 10
    let netrw_liststyle = 3
    let netrw_browse_spit = 4
    let netrw_altv = 1

" Bindings
    map <silent> <leader>o :Lexplore!<CR>
