" Basic stuff
   set mouse=a
   set clipboard+=unnamedplus
   set tabstop=3 shiftwidth=3 softtabstop=3 expandtab
   set wildmode=longest,list,full
   set splitbelow splitright
   set fillchars+=vert:\ 
   set nowrap
   set confirm
   set undofile
   set ignorecase smartcase
   set inccommand=split
   set scrolloff=4
   set termguicolors

" No autocomments
   autocmd FileType * setlocal formatoptions-=cro

" Vimdiff colors
   highlight DiffAdd    cterm=BOLD ctermfg=NONE ctermbg=22 gui=bold guifg=NONE guibg=#005f00
   highlight DiffDelete cterm=BOLD ctermfg=NONE ctermbg=52 gui=bold guifg=NONE guibg=#5f0000
   highlight DiffChange cterm=BOLD ctermfg=NONE ctermbg=23 gui=bold guifg=NONE guibg=#005f5f
   highlight DiffText   cterm=BOLD ctermfg=NONE ctermbg=23 gui=bold guifg=NONE guibg=#005f5f

" Configurations
   set laststatus=2 statusline=%<%f\ %h%m%r%=%-14.(%n:%l,%c%V%)\ %P

   let netrw_winsize = 25

