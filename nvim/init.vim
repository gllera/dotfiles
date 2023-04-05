" Basic stuff
   set mouse=a
   set clipboard+=unnamedplus
   set tabstop=3 shiftwidth=3 expandtab
   set wildmode=longest,list,full
   set splitbelow splitright
   set fillchars+=vert:\ 
   set nowrap
   set confirm

" No autocoments
   autocmd FileType * setlocal formatoptions-=cro

" Vimdiff colors
   highlight DiffAdd    cterm=BOLD ctermfg=NONE ctermbg=22
   highlight DiffDelete cterm=BOLD ctermfg=NONE ctermbg=52
   highlight DiffChange cterm=BOLD ctermfg=NONE ctermbg=23
   highlight DiffText   cterm=BOLD ctermfg=NONE ctermbg=23

" Configurations
   set laststatus=2 statusline=%<%f\ %h%m%r%=%-14.(%n:%l,%c%V%)\ %P

   let netrw_winsize = 25

