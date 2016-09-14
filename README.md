# mini-test-nginx
small reconstruction from test-nginx for learning

### note
注意，这个 mini test-nginx 仅仅用于学习用，想入门学习 test-nginx 是一个不错的选择  
此代码下载后不能直接运行，需要配合自己的需求进行相应的配置和修改  

### 运行过程
清理空间 --> 新建空间 --> 生成 nginx.conf 代码 --> 解析 block --> 通过 Perl 自带的网络 IO 库与 nginx 建立连接 --> 发起请求测试响应  

#### test-nginx 
本项目代码是基于春哥 [agentzh](https://github.com/agentzh) 的 [test-nginx](https://github.com/openresty/test-nginx/) 修改，做学习用途
