let mapleader="\<Space>"

" Basic stuff
   set mouse=a
   set clipboard+=unnamedplus
   set tabstop=3 shiftwidth=3 expandtab
   set wildmode=longest,list,full
   set splitbelow splitright
   set fillchars+=vert:\ 
   set nowrap
   set confirm
   set number

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

   " It's useful to show the buffer number in the status line.
   let g:tmux_navigator_no_mappings = 1
   let g:tmux_navigator_disable_when_zoomed = 1


" Bindings
   " File explorer
   map <silent> <F3> :Lexplore!<CR>
   au FileType netrw nmap <buffer> <Backspace> -

   " Buffers
   " \l  <F5> : list buffers
   " \b \f \g : go back/forward/last-used
   " \1 \2 \3 : go to buffer 1/2/3 etc
   nmap <F5>      :ls<CR>:b<Space>
   nmap <Leader>l :ls<CR>:b<Space>
   nmap <Leader>b :bp<CR>
   nmap <Leader>f :bn<CR>
   nmap <Leader>g :e#<CR>
   nmap <Leader>1 :1b<CR>
   nmap <Leader>2 :2b<CR>
   nmap <Leader>3 :3b<CR>
   nmap <Leader>4 :4b<CR>
   nmap <Leader>5 :5b<CR>
   nmap <Leader>6 :6b<CR>
   nmap <Leader>7 :7b<CR>
   nmap <Leader>8 :8b<CR>
   nmap <Leader>9 :9b<CR>
   nmap <Leader>0 :10b<CR>

   " Fast save and close
   nmap <leader>w :w<CR>
   nmap <leader>x :x<CR>
   nmap <leader>q :q<CR>

   " Split navigation
   nmap <c-j> <c-w><c-j>
   nmap <c-k> <c-w><c-k>
   nmap <c-l> <c-w><c-l>
   nmap <c-h> <c-w><c-h>

   " Tmux integration
   nmap <silent> <M-Left>  :TmuxNavigateLeft<cr>
   nmap <silent> <M-Down>  :TmuxNavigateDown<cr>
   nmap <silent> <M-Up>    :TmuxNavigateUp<cr>
   nmap <silent> <M-Right> :TmuxNavigateRight<cr>
